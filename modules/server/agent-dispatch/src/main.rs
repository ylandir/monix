use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, String>;

const READY_MAX_AGE: u64 = 60;
const PROMPT_MAX_BYTES: u64 = 1_048_576;

const NO_ADVISOR_ANSWER: &[u8] =
    b"No advisor is configured for this task \xe2\x80\x94 proceed on your own best judgment.\n";

#[derive(Clone, Debug)]
struct Config {
    tasks: PathBuf,
    worker: String,
    work: PathBuf,
    creds: PathBuf,
    claude_token: PathBuf,
    codex_auth: PathBuf,
    openrouter_key: Option<PathBuf>,
    readers: String,
    stall_timeout: u64,
    warm_max_age: u64,
    task_timeout: u64,
    exchange_max_bytes: u64,
    context_max_bytes: u64,
}

impl Config {
    fn from_env() -> Result<Self> {
        Ok(Self {
            tasks: env_path("FLEET_TASKS_DIR")?,
            worker: env_string("FLEET_WORKER")?,
            work: env_path("FLEET_WORK_DIR")?,
            creds: env_path("FLEET_CREDS_DIR")?,
            claude_token: env_path("FLEET_CLAUDE_TOKEN_FILE")?,
            codex_auth: env_path("FLEET_CODEX_AUTH_FILE")?,
            openrouter_key: env::var_os("FLEET_OPENROUTER_KEY_FILE")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from),
            readers: env_string("FLEET_READERS")?,
            stall_timeout: env_u64("FLEET_STALL_TIMEOUT")?,
            warm_max_age: env_u64("FLEET_WARM_MAX_AGE")?,
            task_timeout: env_u64("FLEET_TASK_TIMEOUT")?,
            exchange_max_bytes: env_u64("FLEET_TASK_EXCHANGE_MAX_BYTES")?,
            context_max_bytes: env_u64("FLEET_TASK_CONTEXT_MAX_BYTES")?,
        })
    }

    fn queue(&self) -> PathBuf {
        self.tasks.join("queue")
    }

    fn running(&self) -> PathBuf {
        self.tasks.join("running").join(&self.worker)
    }

    fn rejected(&self) -> PathBuf {
        self.tasks.join("rejected")
    }

    fn ready_dir(&self) -> PathBuf {
        PathBuf::from("/run/agents/ready")
    }

    fn live_root(&self) -> PathBuf {
        self.tasks.join("live")
    }

    fn steer_spool(&self) -> PathBuf {
        self.tasks.join("steer")
    }

    fn answer_spool(&self) -> PathBuf {
        self.tasks.join("answers")
    }

    fn cancel_spool(&self) -> PathBuf {
        self.tasks.join("cancel")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum Agent {
    Claude,
    Codex,
    Opencode,
}

impl Agent {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Opencode => "opencode",
        }
    }
}

#[derive(Clone, Debug)]
struct TaskMetadata {
    agent: Agent,
    model: String,
    effort: String,
    guidance: String,
    timeout: u64,
}

#[derive(Debug)]
struct ClaimedTask {
    id: String,
    prompt: PathBuf,
    context: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TaskStatus {
    Done,
    Failed,
    Cancelled,
    InvalidOutput,
    Requeue,
    Stalled,
    Capped,
    Oversize,
}

impl TaskStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Done => "done",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::InvalidOutput => "invalid-output",
            Self::Requeue => "requeue",
            Self::Stalled => "stalled",
            Self::Capped => "capped",
            Self::Oversize => "oversize",
        }
    }
}

#[derive(Debug)]
enum Credential<'a> {
    File {
        source: &'a Path,
        name: &'static str,
    },
    None,
}

struct Dispatcher {
    config: Config,
    systemd: Systemd,
}

struct Systemd {
    unit: String,
}

impl Systemd {
    fn new(worker: &str) -> Self {
        Self {
            unit: format!("microvm@{worker}.service"),
        }
    }

    fn start(&self) -> Result<bool> {
        command_success(Command::new("systemctl").arg("start").arg(&self.unit))
    }

    fn stop(&self) -> Result<()> {
        let status = Command::new("systemctl")
            .arg("stop")
            .arg(&self.unit)
            .status()
            .map_err(|error| format!("stop {}: {error}", self.unit))?;
        require_success(status, &format!("stop {}", self.unit))?;
        let _ = Command::new("systemctl")
            .arg("reset-failed")
            .arg(&self.unit)
            .status();
        Ok(())
    }

    fn active(&self) -> Result<bool> {
        command_success(
            Command::new("systemctl")
                .args(["is-active", "--quiet"])
                .arg(&self.unit),
        )
    }

}

impl Dispatcher {
    fn new(config: Config) -> Self {
        let systemd = Systemd::new(&config.worker);
        Self { config, systemd }
    }

    fn initialize(&self) -> Result<()> {
        ensure_dir(&self.config.running(), 0o755, None)?;
        ensure_dir(&self.config.ready_dir(), 0o755, Some("root:root"))?;
        self.remove_partial_results()?;
        self.requeue_stranded()
    }

    fn remove_partial_results(&self) -> Result<()> {
        let suffix = format!(".{}.tmp", self.config.worker);
        for category in ["done", "failed"] {
            for path in directory_entries(&self.config.tasks.join(category))? {
                let matches = path
                    .file_name()
                    .and_then(OsStr::to_str)
                    .map(|name| name.starts_with('.') && name.ends_with(&suffix))
                    .unwrap_or(false);
                if matches {
                    remove_tree(&path)?;
                }
            }
        }
        Ok(())
    }

    fn run(&self) -> Result<()> {
        self.initialize()?;
        loop {
            self.systemd.stop()?;
            self.reset_work()?;
            self.reset_creds()?;
            if !self.systemd.start()? {
                self.log("warm boot failed (worker would not start), retrying")?;
                self.systemd.stop()?;
                thread::sleep(Duration::from_secs(5));
                continue;
            }
            let vm_started = unix_now();
            if !self.wait_until_ready()? {
                continue;
            }
            let ready_marker = self.config.ready_dir().join(&self.config.worker);
            ensure_marker(&ready_marker, 0o644)?;

            let task = match self.wait_for_task(vm_started)? {
                Some(task) => task,
                None => continue,
            };
            self.process_task(task)?;
        }
    }

    fn wait_until_ready(&self) -> Result<bool> {
        let deadline = unix_now().saturating_add(self.config.stall_timeout);
        while !self.warm_ready() {
            if !self.systemd.active()? {
                self.log("warm VM died before becoming ready, recycling")?;
                return Ok(false);
            }
            if unix_now() >= deadline {
                self.log(&format!(
                    "warm VM did not become ready within {}s, recycling",
                    self.config.stall_timeout
                ))?;
                return Ok(false);
            }
            thread::sleep(Duration::from_secs(1));
        }
        Ok(true)
    }

    fn wait_for_task(&self, vm_started: u64) -> Result<Option<ClaimedTask>> {
        loop {
            if let Some(task) = self.claim_next()? {
                return Ok(Some(task));
            }
            thread::sleep(Duration::from_secs(2));
            if !self.systemd.active()? {
                self.log("warm VM died while idle, recycling")?;
                return Ok(None);
            }
            if !self.warm_ready() {
                self.log("warm VM stopped refreshing readiness while idle, recycling")?;
                return Ok(None);
            }
            if unix_now().saturating_sub(vm_started) >= self.config.warm_max_age {
                self.log(&format!(
                    "recycling warm VM after {}s idle (preventive)",
                    self.config.warm_max_age
                ))?;
                return Ok(None);
            }
        }
    }

    fn process_task(&self, mut task: ClaimedTask) -> Result<()> {
        let start = unix_now();
        if let Err(error) = self.try_process_task(&mut task, start) {
            self.fail_task(&task, start, &error)?;
        }
        Ok(())
    }

    fn try_process_task(&self, task: &mut ClaimedTask, start: u64) -> Result<()> {
        let live = self.config.live_root().join(&task.id);

        if !self.systemd.active()? || !self.warm_ready() {
            self.log(&format!(
                "warm VM died or went stale before dispatch, requeueing {}",
                task.id
            ))?;
            self.requeue_claim(task, false)?;
            return Ok(());
        }

        remove_tree(&live)?;
        let pending_cancel = self.pending_cancel(task)?;
        let (metadata, mut rejection) =
            match TaskMetadata::read(&task.prompt, self.config.task_timeout) {
                Ok(metadata) => (metadata, None),
                Err(error) => (
                    TaskMetadata::rejected(self.config.task_timeout),
                    Some(error),
                ),
            };
        if !pending_cancel && rejection.is_none() {
            match self.stage_credential(&metadata) {
                Ok(()) => self.stage_metadata(&metadata)?,
                Err(error) => {
                    rejection = Some(error);
                }
            }
        }
        ensure_dir(&live, 0o750, Some(&format!("root:{}", self.config.readers)))?;

        if let Some(error) = rejection {
            self.log(&format!("rejected {} ({error})", task.id))?;
            write_new_or_replace(
                &self.config.work.join("report.md"),
                format!("task rejected: {error}\n").as_bytes(),
                0o644,
            )?;
            write_new_or_replace(&self.config.work.join("exit-code"), b"66\n", 0o644)?;
        } else if !pending_cancel {
            if let Some(context) = &task.context {
                self.safe_transfer(
                    context,
                    &self.config.work.join("context.tar.zst"),
                    self.config.context_max_bytes,
                    0o444,
                )?;
            }
            let temporary = self.config.work.join(".prompt.md.tmp");
            remove_any(&temporary)?;
            self.safe_transfer(&task.prompt, &temporary, PROMPT_MAX_BYTES, 0o444)?;
            fs::rename(&temporary, self.config.work.join("prompt.md"))
                .context("publish prompt.md")?;
            self.log(&format!(
                "DISPATCH {} agent={}{}{}",
                task.id,
                metadata.agent.as_str(),
                optional_field("model", &metadata.model),
                optional_field("guidance", &metadata.guidance)
            ))?;
        }

        let status = self.monitor(task, &metadata, &live)?;
        self.systemd.stop()?;
        self.reset_creds()?;

        if status == TaskStatus::Requeue {
            self.requeue_claim(task, true)?;
            remove_tree(&live)?;
            self.reset_work()?;
            return Ok(());
        }

        self.archive(task, status, start, &live)?;
        Ok(())
    }

    fn fail_task(&self, task: &ClaimedTask, start: u64, error: &str) -> Result<()> {
        let _ = self.log(&format!("ERROR {} ({error})", task.id));
        self.systemd.stop()?;
        self.reset_creds()?;
        if self.final_result_exists(&task.id) {
            self.cleanup_finalized(&task.id, &task.prompt, task.context.as_deref())?;
            return Ok(());
        }

        self.reset_work()?;
        let live = self.config.live_root().join(&task.id);
        remove_tree(&live)?;
        ensure_dir(&live, 0o750, Some(&format!("root:{}", self.config.readers)))?;
        write_new(
            &self.config.work.join("report.md"),
            format!("task failed in host dispatcher: {error}\n").as_bytes(),
            0o644,
        )?;
        write_new(&self.config.work.join("exit-code"), b"70\n", 0o644)?;
        self.archive(task, TaskStatus::InvalidOutput, start, &live)
    }

    fn monitor(
        &self,
        task: &ClaimedTask,
        metadata: &TaskMetadata,
        live: &Path,
    ) -> Result<TaskStatus> {
        let hard_deadline = unix_now().saturating_add(metadata.timeout);
        let mut last_progress = unix_now();
        let mut last_heartbeat = 0;
        let mut last_progress_mtime = 0;
        let mut last_log_mtime = 0;
        let mut seen_questions = BTreeSet::new();

        loop {
            let now = unix_now();
            if exists_any(&self.config.cancel_spool().join(&task.id)) {
                self.log(&format!("CANCELLED {} (cockpit request)", task.id))?;
                return Ok(TaskStatus::Cancelled);
            }
            let exit_code = self.config.work.join("exit-code");
            if exists_any(&exit_code) {
                // Bounded fd-based read: uid and size are checked on the open
                // descriptor, so the executor cannot race the checks.
                match read_bounded_owned(&exit_code, 64, Some(0)) {
                    Ok(value) => return Ok(exit_status(&value)),
                    Err(error) => {
                        self.log(&format!(
                            "rejected {} exit-code (unsafe or oversized file): {error}",
                            task.id
                        ))?;
                        return Ok(TaskStatus::InvalidOutput);
                    }
                }
            }

            let heartbeat = mtime(&self.config.work.join(".heartbeat")).unwrap_or(0);
            if heartbeat != last_heartbeat {
                last_heartbeat = heartbeat;
                last_progress = now;
            }
            let was_requeued = exists_any(&self.config.tasks.join(".requeued").join(&task.id));
            if let Some(decision) = deadline_decision(
                now,
                last_progress,
                last_heartbeat,
                self.config.stall_timeout,
                hard_deadline,
                was_requeued,
            ) {
                match decision {
                    TaskStatus::Requeue => self.log(&format!(
                        "STALLED {} before pickup (no heartbeat ever), requeueing once",
                        task.id
                    ))?,
                    TaskStatus::Stalled => self.log(&format!(
                        "STALLED {} (no heartbeat for {}s)",
                        task.id, self.config.stall_timeout
                    ))?,
                    TaskStatus::Capped => self.log(&format!(
                        "CAP {} (hit absolute {}s cap)",
                        task.id, metadata.timeout
                    ))?,
                    _ => return Err("invalid internal deadline decision".into()),
                }
                return Ok(decision);
            }

            if let Ok(exchange_size) = directory_apparent_size(&self.config.work)
                && exchange_size > self.config.exchange_max_bytes
            {
                self.log(&format!(
                    "OVERSIZE {} (task exchange exceeded {} bytes)",
                    task.id, self.config.exchange_max_bytes
                ))?;
                return Ok(TaskStatus::Oversize);
            }

            self.publish_live_file(
                &self.config.work.join("progress.md"),
                &live.join("progress.md"),
                &mut last_progress_mtime,
                1_048_576,
            )?;
            self.publish_log_tail(live, &mut last_log_mtime)?;
            self.relay_steering(task, live)?;
            self.relay_cockpit_answers(task, live)?;
            self.relay_questions(task, metadata, live, &mut seen_questions)?;
            thread::sleep(Duration::from_secs(10));
        }
    }

    fn warm_ready(&self) -> bool {
        let ready = self.config.work.join(".ready");
        mtime(&ready)
            .map(|modified| unix_now().saturating_sub(modified) <= READY_MAX_AGE)
            .unwrap_or(false)
    }

    fn reset_work(&self) -> Result<()> {
        remove_any(&self.config.ready_dir().join(&self.config.worker))?;
        remove_tree(&self.config.work)?;
        ensure_dir(&self.config.work, 0o770, Some("root:users"))
    }

    fn reset_creds(&self) -> Result<()> {
        for path in directory_entries(&self.config.creds)? {
            let metadata = fs::symlink_metadata(&path).context("inspect credential entry")?;
            if metadata.file_type().is_dir() {
                fs::remove_dir(&path).context("remove credential directory")?;
            } else {
                fs::remove_file(&path).context("remove credential entry")?;
            }
        }
        set_mode(&self.config.creds, 0o700)?;
        chown(&self.config.creds, "root:root")
    }

    fn stage_credential(&self, metadata: &TaskMetadata) -> Result<()> {
        self.reset_creds()?;
        match select_credential(&self.config, metadata)? {
            Credential::None => Ok(()),
            Credential::File { source, name } => {
                let temporary = self.config.creds.join(".credential.tmp");
                remove_any(&temporary)?;
                copy_new(source, &temporary, 0o400, true)?;
                chown(&temporary, "root:root")?;
                fs::rename(&temporary, self.config.creds.join(name))
                    .context("publish selected credential")
            }
        }
    }

    fn stage_metadata(&self, metadata: &TaskMetadata) -> Result<()> {
        let temporary = self.config.creds.join(".task-meta.tmp");
        remove_any(&temporary)?;
        let contents = format!(
            "agent={}\nmodel={}\neffort={}\n",
            metadata.agent.as_str(),
            metadata.model,
            metadata.effort
        );
        write_new(&temporary, contents.as_bytes(), 0o400)?;
        chown(&temporary, "root:root")?;
        fs::rename(&temporary, self.config.creds.join("task-meta")).context("publish task metadata")
    }

    fn requeue_stranded(&self) -> Result<()> {
        let running = self.config.running();
        for prompt in markdown_entries(&running)? {
            let id = file_stem_utf8(&prompt)?;
            let context = running.join(format!("{id}.context.tar.zst"));
            if self.final_result_exists(&id) {
                self.cleanup_finalized(&id, &prompt, Some(&context))?;
                continue;
            }
            println!("requeueing stranded {id}.md");
            if is_regular_nofollow(&context) {
                rename_replace(
                    &context,
                    &self.config.queue().join(format!("{id}.context.tar.zst")),
                )?;
            } else {
                remove_any(&context)?;
            }
            rename_replace(&prompt, &self.config.queue().join(format!("{id}.md")))?;
        }
        Ok(())
    }

    fn final_result_exists(&self, id: &str) -> bool {
        exists_any(&self.config.tasks.join("done").join(id))
            || exists_any(&self.config.tasks.join("failed").join(id))
    }

    fn cleanup_finalized(&self, id: &str, prompt: &Path, context: Option<&Path>) -> Result<()> {
        remove_any(prompt)?;
        if let Some(context) = context {
            remove_any(context)?;
        }
        remove_tree(&self.config.live_root().join(id))?;
        self.remove_task_spool(&self.config.steer_spool(), &format!("{id}.message-"))?;
        self.remove_task_spool(&self.config.answer_spool(), &format!("{id}.answer-"))?;
        remove_any(&self.config.cancel_spool().join(id))?;
        remove_any(&self.config.tasks.join(".requeued").join(id))
    }

    fn claim_next(&self) -> Result<Option<ClaimedTask>> {
        loop {
            let mut queued = markdown_entries(&self.config.queue())?;
            queued.sort_by(|left, right| {
                mtime(left)
                    .unwrap_or(u64::MAX)
                    .cmp(&mtime(right).unwrap_or(u64::MAX))
                    .then_with(|| left.cmp(right))
            });
            let Some(source) = queued.into_iter().next() else {
                return Ok(None);
            };
            let id = file_stem_utf8(&source)?;
            let source_context = self.config.queue().join(format!("{id}.context.tar.zst"));
            if exists_any(&self.config.tasks.join("done").join(&id))
                || exists_any(&self.config.tasks.join("failed").join(&id))
            {
                remove_any(&source)?;
                remove_any(&source_context)?;
                self.log(&format!("ignored duplicate terminal task {id}"))?;
                continue;
            }
            let claimed = self.config.running().join(format!("{id}.md"));
            match fs::rename(&source, &claimed) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(format!("claim {}: {error}", source.display())),
            }
            if !regular_bounded(&claimed, PROMPT_MAX_BYTES) {
                ensure_dir(&self.config.rejected(), 0o750, None)?;
                let rejected = self.config.rejected().join(format!("{id}.md"));
                if fs::rename(&claimed, &rejected).is_err() {
                    remove_any(&claimed)?;
                }
                remove_any(&source_context)?;
                self.log(&format!("rejected {id} (unsafe or oversized queue entry)"))?;
                continue;
            }

            let running_context = self.config.running().join(format!("{id}.context.tar.zst"));
            let context = if exists_any(&source_context) {
                let safe = fs::rename(&source_context, &running_context).is_ok()
                    && regular_bounded(&running_context, self.config.context_max_bytes);
                if !safe {
                    ensure_dir(&self.config.rejected(), 0o750, None)?;
                    let rejected = self.config.rejected().join(format!("{id}.md"));
                    if fs::rename(&claimed, &rejected).is_err() {
                        remove_any(&claimed)?;
                    }
                    remove_any(&running_context)?;
                    remove_any(&source_context)?;
                    self.log(&format!("rejected {id} (unsafe context archive)"))?;
                    continue;
                }
                Some(running_context)
            } else {
                None
            };
            return Ok(Some(ClaimedTask {
                id,
                prompt: claimed,
                context,
            }));
        }
    }

    fn pending_cancel(&self, task: &ClaimedTask) -> Result<bool> {
        Ok(exists_any(&self.config.cancel_spool().join(&task.id)))
    }

    fn requeue_claim(&self, task: &mut ClaimedTask, mark: bool) -> Result<()> {
        if mark {
            let markers = self.config.tasks.join(".requeued");
            ensure_dir(&markers, 0o755, None)?;
            ensure_marker(&markers.join(&task.id), 0o644)?;
        }
        if let Some(context) = task.context.take() {
            rename_replace(
                &context,
                &self
                    .config
                    .queue()
                    .join(format!("{}.context.tar.zst", task.id)),
            )?;
        }
        rename_replace(
            &task.prompt,
            &self.config.queue().join(format!("{}.md", task.id)),
        )
    }

    fn safe_transfer(
        &self,
        source: &Path,
        destination: &Path,
        limit: u64,
        mode: u32,
    ) -> Result<()> {
        self.safe_transfer_owned(source, destination, limit, mode, None)
    }

    fn safe_transfer_owned(
        &self,
        source: &Path,
        destination: &Path,
        limit: u64,
        mode: u32,
        expected_uid: Option<u32>,
    ) -> Result<()> {
        let input = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(source)
            .with_context(|| format!("open bounded source {}", source.display()))?;
        let metadata = input
            .metadata()
            .with_context(|| format!("inspect bounded source {}", source.display()))?;
        if !metadata.file_type().is_file()
            || metadata.len() > limit
            || expected_uid.is_some_and(|uid| metadata.uid() != uid)
        {
            return Err(format!("unsafe or oversized source: {}", source.display()));
        }

        let copy = (|| {
            let mut output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(mode)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(destination)
                .with_context(|| format!("create bounded destination {}", destination.display()))?;
            let copied = std::io::copy(&mut input.take(limit.saturating_add(1)), &mut output)
                .context("copy bounded file")?;
            if copied > limit {
                return Err(format!("source grew beyond {limit} bytes"));
            }
            output.sync_all().context("sync bounded destination")
        })();
        if copy.is_err() {
            let _ = fs::remove_file(destination);
        }
        copy
    }

    fn publish_live_file(
        &self,
        source: &Path,
        destination: &Path,
        previous_mtime: &mut i64,
        limit: u64,
    ) -> Result<()> {
        let current = mtime(source).unwrap_or(0) as i64;
        if current == *previous_mtime {
            return Ok(());
        }
        *previous_mtime = current;
        let temporary = destination.with_file_name(".progress.tmp");
        remove_any(&temporary)?;
        if self.safe_transfer(source, &temporary, limit, 0o640).is_ok() {
            chown(&temporary, &format!("root:{}", self.config.readers))?;
            rename_replace(&temporary, destination)?;
        }
        Ok(())
    }

    fn publish_log_tail(&self, live: &Path, previous_mtime: &mut i64) -> Result<()> {
        let source = self.config.work.join("agent.log");
        let current = mtime(&source).unwrap_or(0) as i64;
        if current == *previous_mtime {
            return Ok(());
        }
        *previous_mtime = current;
        let full = live.join(".log.tmp");
        let tail = live.join(".tail.tmp");
        remove_any(&full)?;
        remove_any(&tail)?;
        if self
            .safe_transfer(&source, &full, 52_428_800, 0o600)
            .is_ok()
        {
            copy_tail(&full, &tail, 65_536, 0o640)?;
            chown(&tail, &format!("root:{}", self.config.readers))?;
            rename_replace(&tail, &live.join("agent-tail.log"))?;
        }
        remove_any(&full)
    }

    fn relay_steering(&self, task: &ClaimedTask, live: &Path) -> Result<()> {
        let prefix = format!("{}.message-", task.id);
        for source in prefixed_entries(&self.config.steer_spool(), &prefix, ".md")? {
            let Some(token) = suffix_token(&source, &prefix, ".md") else {
                remove_any(&source)?;
                continue;
            };
            let Ok(number) = token.parse::<u32>() else {
                remove_any(&source)?;
                continue;
            };
            if !(1..=32).contains(&number) {
                remove_any(&source)?;
                continue;
            }
            let work_destination = self.config.work.join(format!("message-{token}.md"));
            if self
                .safe_transfer(&source, &work_destination, 65_536, 0o444)
                .is_ok()
            {
                let live_destination = live.join(format!("message-{token}.md"));
                remove_any(&live_destination)?;
                if self
                    .safe_transfer(&source, &live_destination, 65_536, 0o640)
                    .is_ok()
                {
                    chown(&live_destination, &format!("root:{}", self.config.readers))?;
                }
                self.log(&format!("STEERED {} message {token}", task.id))?;
            } else {
                self.log(&format!(
                    "rejected {} steer {token} (unsafe spool entry or blocked delivery)",
                    task.id
                ))?;
            }
            remove_any(&source)?;
        }
        Ok(())
    }

    fn relay_cockpit_answers(&self, task: &ClaimedTask, live: &Path) -> Result<()> {
        let prefix = format!("{}.answer-", task.id);
        for source in prefixed_entries(&self.config.answer_spool(), &prefix, ".md")? {
            let Some(number) = numbered_suffix(&source, &prefix, ".md") else {
                remove_any(&source)?;
                continue;
            };
            if !(1..=5).contains(&number) {
                remove_any(&source)?;
                continue;
            }
            let live_answer = live.join(format!("answer-{number}.md"));
            if !live_answer.exists() {
                let delivered = self.config.work.join(format!("answer-{number}.md"));
                if self
                    .safe_transfer(&source, &delivered, 1_048_576, 0o644)
                    .is_ok()
                {
                    if self
                        .safe_transfer(&source, &live_answer, 1_048_576, 0o640)
                        .is_ok()
                    {
                        chown(&live_answer, &format!("root:{}", self.config.readers))?;
                    }
                    self.log(&format!("ANSWERED {} question {number} (cockpit)", task.id))?;
                } else {
                    self.log(&format!(
                        "rejected {} answer {number} (unsafe spool entry or blocked delivery)",
                        task.id
                    ))?;
                }
            }
            remove_any(&source)?;
        }
        Ok(())
    }

    // `guidance: cockpit` questions surface in the live view for `fleet
    // answer`; anything else is answered immediately with the stock text —
    // there is no advisor tier, the cockpit is the only oracle, and an
    // unattended task is expected to state what is missing and exit.
    fn relay_questions(
        &self,
        task: &ClaimedTask,
        metadata: &TaskMetadata,
        live: &Path,
        seen: &mut BTreeSet<u32>,
    ) -> Result<()> {
        for source in prefixed_entries(&self.config.work, "question-", ".md")? {
            let Some(number) = numbered_suffix(&source, "question-", ".md") else {
                continue;
            };
            if !(1..=5).contains(&number) {
                continue;
            }
            if metadata.guidance == "cockpit" {
                let live_question = live.join(format!("question-{number}.md"));
                let answered = live.join(format!("answer-{number}.md"));
                if !live_question.exists() && !answered.exists() {
                    let temporary = live.join(format!(".question-{number}.tmp"));
                    remove_any(&temporary)?;
                    if self
                        .safe_transfer(&source, &temporary, 65_536, 0o640)
                        .is_ok()
                    {
                        chown(&temporary, &format!("root:{}", self.config.readers))?;
                        rename_replace(&temporary, &live_question)?;
                    } else {
                        self.log(&format!(
                            "rejected {} question {number} (unsafe or oversized file)",
                            task.id
                        ))?;
                    }
                }
                if seen.insert(number) {
                    self.log(&format!(
                        "ESCALATE {} question {number} -> cockpit",
                        task.id
                    ))?;
                }
                continue;
            }

            let answer = self.config.work.join(format!("answer-{number}.md"));
            if !exists_any(&answer)
                && write_new(&answer, NO_ADVISOR_ANSWER, 0o644).is_ok()
                && seen.insert(number)
            {
                self.log(&format!(
                    "ANSWERED {} question {number} (no advisor)",
                    task.id
                ))?;
            }
        }
        Ok(())
    }

    fn archive(
        &self,
        task: &ClaimedTask,
        status: TaskStatus,
        start: u64,
        live: &Path,
    ) -> Result<()> {
        let root = if status == TaskStatus::Done {
            self.config.tasks.join("done")
        } else {
            self.config.tasks.join("failed")
        };
        let final_output = root.join(&task.id);
        let output = root.join(format!(".{}.{}.tmp", task.id, self.config.worker));
        remove_tree(&output)?;
        ensure_dir(
            &output,
            0o750,
            Some(&format!("root:{}", self.config.readers)),
        )?;
        self.safe_transfer(
            &task.prompt,
            &output.join("prompt.md"),
            PROMPT_MAX_BYTES,
            0o640,
        )?;
        chown(
            &output.join("prompt.md"),
            &format!("root:{}", self.config.readers),
        )?;
        write_new_or_replace(
            &output.join("status"),
            format!("{}\n", status.as_str()).as_bytes(),
            0o640,
        )?;
        chown(
            &output.join("status"),
            &format!("root:{}", self.config.readers),
        )?;

        for (source, name, limit, expected_uid) in [
            (
                self.config.work.join("report.md"),
                "report.md",
                10_485_760,
                None,
            ),
            (
                self.config.work.join("agent.log"),
                "agent.log",
                52_428_800,
                None,
            ),
            (self.config.work.join("exit-code"), "exit-code", 64, Some(0)),
            (
                self.config.work.join("changes.patch"),
                "changes.patch",
                52_428_800,
                None,
            ),
            (
                self.config.work.join(".trusted/usage.json"),
                "usage.json",
                65_536,
                Some(0),
            ),
        ] {
            self.archive_file(task, &source, &output.join(name), limit, expected_uid)?;
        }
        for source in prefixed_entries(&self.config.work, "answer-", ".md")? {
            let Some(number) = numbered_suffix(&source, "answer-", ".md") else {
                let name = source
                    .file_name()
                    .and_then(OsStr::to_str)
                    .unwrap_or("invalid");
                self.log(&format!(
                    "rejected {} output {name} (invalid answer name)",
                    task.id
                ))?;
                continue;
            };
            if (1..=5).contains(&number) {
                self.archive_file(
                    task,
                    &source,
                    &output.join(format!("answer-{number}.md")),
                    1_048_576,
                    None,
                )?;
            }
        }
        if is_regular_follow(&live.join("progress.md")) {
            trusted_copy_replace(
                &live.join("progress.md"),
                &output.join("progress.md"),
                0o640,
            )?;
            chown(
                &output.join("progress.md"),
                &format!("root:{}", self.config.readers),
            )?;
        }
        for prefix in ["message-", "question-"] {
            for source in prefixed_entries(live, prefix, ".md")? {
                let Some(name) = source.file_name() else {
                    continue;
                };
                trusted_copy_replace(&source, &output.join(name), 0o640)?;
                chown(&output.join(name), &format!("root:{}", self.config.readers))?;
            }
        }

        fs::rename(&output, &final_output).with_context(|| {
            format!(
                "publish result {} as {}",
                output.display(),
                final_output.display()
            )
        })?;

        self.cleanup_finalized(&task.id, &task.prompt, task.context.as_deref())?;
        self.reset_work()?;

        let escalations = prefixed_entries(&final_output, "answer-", ".md")?
            .into_iter()
            .filter(|path| is_regular_follow(path))
            .count();
        let duration = unix_now().saturating_sub(start);
        let report = fs::metadata(final_output.join("report.md"))
            .map(|metadata| format!("report {} bytes", metadata.len()))
            .unwrap_or_else(|_| "no report".into());
        let tokens = usage_summary(&final_output.join("usage.json"));
        self.log(&format!(
            "{} {} ran {}m{}s, {} escalation(s), {}{}",
            status.as_str().to_uppercase(),
            task.id,
            duration / 60,
            duration % 60,
            escalations,
            report,
            tokens
        ))
    }

    fn archive_file(
        &self,
        task: &ClaimedTask,
        source: &Path,
        destination: &Path,
        limit: u64,
        expected_uid: Option<u32>,
    ) -> Result<()> {
        if !exists_any(source) {
            return Ok(());
        }
        if self
            .safe_transfer_owned(source, destination, limit, 0o640, expected_uid)
            .is_ok()
        {
            chown(destination, &format!("root:{}", self.config.readers))?;
        } else {
            let name = source
                .file_name()
                .and_then(OsStr::to_str)
                .unwrap_or("invalid");
            self.log(&format!(
                "rejected {} output {name} (unsafe or oversized file)",
                task.id
            ))?;
        }
        Ok(())
    }

    fn remove_task_spool(&self, directory: &Path, prefix: &str) -> Result<()> {
        for path in prefixed_entries(directory, prefix, ".md")? {
            remove_any(&path)?;
        }
        Ok(())
    }

    fn log(&self, message: &str) -> Result<()> {
        let line = format!("{} {} {}\n", timestamp(), self.config.worker, message);
        print!("{line}");
        let mut log = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.config.tasks.join("log"))
            .context("open fleet audit log")?;
        log.write_all(line.as_bytes())
            .context("append fleet audit log")
    }
}

impl TaskMetadata {
    fn read(path: &Path, default_timeout: u64) -> Result<Self> {
        let fields = frontmatter(path)?;
        let agent = match token(&fields, "agent")?.as_str() {
            "claude" => Agent::Claude,
            "codex" => Agent::Codex,
            "opencode" => Agent::Opencode,
            value => return Err(format!("unsupported agent: {value}")),
        };
        let requested_timeout = fields
            .get("timeout")
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| (1..=default_timeout).contains(value))
            .unwrap_or(default_timeout);
        Ok(Self {
            agent,
            model: token(&fields, "model")?,
            effort: token(&fields, "effort")?,
            guidance: token(&fields, "guidance")?,
            timeout: requested_timeout,
        })
    }

    // Placeholder for tasks whose front-matter was rejected: never dispatched,
    // only the timeout and (empty) guidance are consulted while monitoring.
    fn rejected(timeout: u64) -> Self {
        Self {
            agent: Agent::Claude,
            model: String::new(),
            effort: String::new(),
            guidance: String::new(),
            timeout,
        }
    }
}

fn select_credential<'a>(config: &'a Config, task: &TaskMetadata) -> Result<Credential<'a>> {
    match (&task.agent, task.model.as_str()) {
        (Agent::Claude, model) if !model.is_empty() => Ok(Credential::File {
            source: &config.claude_token,
            name: "claude-token",
        }),
        (Agent::Codex, model) if !model.is_empty() => Ok(Credential::File {
            source: &config.codex_auth,
            name: "codex-auth.json",
        }),
        (Agent::Opencode, model) if model.starts_with("openrouter/") => {
            let source = config
                .openrouter_key
                .as_deref()
                .ok_or_else(|| "openrouter credential is not configured".to_string())?;
            Ok(Credential::File {
                source,
                name: "openrouter-key",
            })
        }
        (Agent::Opencode, model) if model.starts_with("local/") => Ok(Credential::None),
        _ => Err(format!(
            "unsupported agent/model combination: {}/{}",
            task.agent.as_str(),
            task.model
        )),
    }
}

fn frontmatter(path: &Path) -> Result<BTreeMap<String, String>> {
    let file = File::open(path).context("open claimed prompt")?;
    let mut lines = BufReader::new(file).lines();
    if lines
        .next()
        .transpose()
        .context("read prompt front-matter")?
        .as_deref()
        != Some("---")
    {
        return Ok(BTreeMap::new());
    }
    let mut fields = BTreeMap::new();
    let mut closed = false;
    for line in lines {
        let line = line.context("read prompt front-matter")?;
        if line == "---" {
            closed = true;
            break;
        }
        if let Some((key, value)) = line.split_once(':') {
            fields
                .entry(key.into())
                .or_insert_with(|| value.trim_start().into());
        }
    }
    if !closed {
        return Err("unterminated prompt front-matter".into());
    }
    Ok(fields)
}

fn token(fields: &BTreeMap<String, String>, name: &str) -> Result<String> {
    let value = fields.get(name).map(String::as_str).unwrap_or("");
    if value.len() > 64
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._/-".contains(character))
    {
        return Err(format!("invalid {name}"));
    }
    Ok(value.into())
}

fn env_string(name: &str) -> Result<String> {
    env::var(name).map_err(|_| format!("required environment variable {name} is missing"))
}

fn env_path(name: &str) -> Result<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| format!("required environment variable {name} is missing"))
}

fn env_u64(name: &str) -> Result<u64> {
    env_string(name)?
        .parse()
        .map_err(|error| format!("invalid {name}: {error}"))
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// `date '+%F %T'` in local time, without the subprocess.
fn timestamp() -> String {
    let tm = unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        tm
    };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

fn mtime(path: &Path) -> Option<u64> {
    fs::symlink_metadata(path)
        .ok()
        .filter(|metadata| metadata.file_type().is_file())
        .and_then(|metadata| u64::try_from(metadata.mtime()).ok())
}

fn exists_any(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn is_regular_nofollow(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_file())
        .unwrap_or(false)
}

/// Bounded read of a worker-reachable file: O_NOFOLLOW open, then type/size/
/// owner checks on the descriptor so nothing can be swapped between check and
/// read.
fn read_bounded_owned(path: &Path, limit: u64, expected_uid: Option<u32>) -> Result<Vec<u8>> {
    let input = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("open bounded source {}", path.display()))?;
    let metadata = input
        .metadata()
        .with_context(|| format!("inspect bounded source {}", path.display()))?;
    if !metadata.file_type().is_file()
        || metadata.len() > limit
        || expected_uid.is_some_and(|uid| metadata.uid() != uid)
    {
        return Err(format!("unsafe or oversized source: {}", path.display()));
    }
    let mut bytes = Vec::new();
    input
        .take(limit.saturating_add(1))
        .read_to_end(&mut bytes)
        .context("read bounded source")?;
    if bytes.len() as u64 > limit {
        return Err(format!("source grew beyond {limit} bytes"));
    }
    Ok(bytes)
}

fn regular_bounded(path: &Path, limit: u64) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_file() && metadata.len() <= limit)
        .unwrap_or(false)
}

fn is_regular_follow(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.file_type().is_file())
        .unwrap_or(false)
}

fn ensure_dir(path: &Path, mode: u32, owner: Option<&str>) -> Result<()> {
    fs::create_dir_all(path).with_context(|| format!("create directory {}", path.display()))?;
    set_mode(path, mode)?;
    if let Some(owner) = owner {
        chown(path, owner)?;
    }
    Ok(())
}

fn set_mode(path: &Path, mode: u32) -> Result<()> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .with_context(|| format!("chmod {:04o} {}", mode, path.display()))
}

fn chown(path: &Path, owner: &str) -> Result<()> {
    let status = Command::new("chown")
        .arg(owner)
        .arg(path)
        .status()
        .map_err(|error| format!("run chown for {}: {error}", path.display()))?;
    require_success(status, &format!("chown {owner} {}", path.display()))
}

fn ensure_marker(path: &Path, mode: u32) -> Result<()> {
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(false);
    options
        .open(path)
        .with_context(|| format!("touch {}", path.display()))?;
    set_mode(path, mode)
}

fn remove_any(path: &Path) -> Result<()> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if metadata.file_type().is_dir() {
        fs::remove_dir(path).with_context(|| format!("remove directory {}", path.display()))
    } else {
        fs::remove_file(path).with_context(|| format!("remove file {}", path.display()))
    }
}

fn remove_tree(path: &Path) -> Result<()> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if metadata.file_type().is_dir() {
        fs::remove_dir_all(path).with_context(|| format!("remove tree {}", path.display()))
    } else {
        fs::remove_file(path).with_context(|| format!("remove file {}", path.display()))
    }
}

fn rename_replace(source: &Path, destination: &Path) -> Result<()> {
    fs::rename(source, destination)
        .with_context(|| format!("rename {} to {}", source.display(), destination.display()))
}

fn write_new(path: &Path, contents: &[u8], mode: u32) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)
        .with_context(|| format!("create {}", path.display()))?;
    file.write_all(contents)
        .with_context(|| format!("write {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("sync {}", path.display()))
}

fn write_new_or_replace(path: &Path, contents: &[u8], mode: u32) -> Result<()> {
    remove_any(path)?;
    write_new(path, contents, mode)
}

/// Copy a trusted source to a fresh destination. `follow_source` only for
/// operator-managed inputs (credentials may live behind agenix symlinks);
/// worker-reachable paths must pass `false`.
fn copy_new(source: &Path, destination: &Path, mode: u32, follow_source: bool) -> Result<()> {
    let regular = if follow_source {
        fs::metadata(source)
            .map(|metadata| metadata.file_type().is_file())
            .unwrap_or(false)
    } else {
        is_regular_nofollow(source)
    };
    if !regular {
        return Err(format!("{} is not a regular file", source.display()));
    }
    let mut input = File::open(source).with_context(|| format!("open {}", source.display()))?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(destination)
        .with_context(|| format!("create {}", destination.display()))?;
    std::io::copy(&mut input, &mut output).context("copy regular file")?;
    output.sync_all().context("sync copied file")
}

fn trusted_copy_replace(source: &Path, destination: &Path, mode: u32) -> Result<()> {
    let temporary = destination.with_extension("tmp");
    remove_any(&temporary)?;
    copy_new(source, &temporary, mode, false)?;
    rename_replace(&temporary, destination)
}

fn copy_tail(source: &Path, destination: &Path, limit: u64, mode: u32) -> Result<()> {
    let mut input = File::open(source).context("open staged log")?;
    let length = input.metadata().context("stat staged log")?.len();
    if length > limit {
        use std::io::Seek;
        input
            .seek(std::io::SeekFrom::Start(length - limit))
            .context("seek staged log")?;
    }
    let mut bytes = Vec::with_capacity(limit as usize);
    input
        .take(limit)
        .read_to_end(&mut bytes)
        .context("read staged log tail")?;
    write_new(destination, &bytes, mode)
}

fn directory_entries(directory: &Path) -> Result<Vec<PathBuf>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(directory)
        .with_context(|| format!("read directory {}", directory.display()))?
    {
        entries.push(entry.context("read directory entry")?.path());
    }
    entries.sort();
    Ok(entries)
}

fn markdown_entries(directory: &Path) -> Result<Vec<PathBuf>> {
    Ok(directory_entries(directory)?
        .into_iter()
        .filter(|path| path.extension() == Some(OsStr::new("md")))
        .collect())
}

fn prefixed_entries(directory: &Path, prefix: &str, suffix: &str) -> Result<Vec<PathBuf>> {
    Ok(directory_entries(directory)?
        .into_iter()
        .filter(|path| {
            path.file_name()
                .and_then(OsStr::to_str)
                .map(|name| name.starts_with(prefix) && name.ends_with(suffix))
                .unwrap_or(false)
        })
        .collect())
}

fn file_stem_utf8(path: &Path) -> Result<String> {
    path.file_stem()
        .and_then(OsStr::to_str)
        .map(String::from)
        .ok_or_else(|| format!("non-UTF-8 task id: {}", path.display()))
}

fn numbered_suffix(path: &Path, prefix: &str, suffix: &str) -> Option<u32> {
    let token = suffix_token(path, prefix, suffix)?;
    let number: u32 = token.parse().ok()?;
    (number.to_string() == token).then_some(number)
}

fn suffix_token<'a>(path: &'a Path, prefix: &str, suffix: &str) -> Option<&'a str> {
    path.file_name()
        .and_then(OsStr::to_str)
        .and_then(|name| name.strip_prefix(prefix))
        .and_then(|name| name.strip_suffix(suffix))
}

/// Apparent size of everything under `path` (the `du -sb` this replaces
/// summed directory and symlink sizes too; the exchange cap is a guardrail,
/// not exact accounting, so entry lengths are summed the same way).
fn directory_apparent_size(path: &Path) -> Result<u64> {
    let mut total = fs::symlink_metadata(path)
        .with_context(|| format!("inspect {}", path.display()))?
        .len();
    let mut pending = vec![path.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in directory_entries(&directory)? {
            let Ok(metadata) = fs::symlink_metadata(&entry) else {
                continue;
            };
            total = total.saturating_add(metadata.len());
            if metadata.file_type().is_dir() {
                pending.push(entry);
            }
        }
    }
    Ok(total)
}

fn optional_field(name: &str, value: &str) -> String {
    if value.is_empty() {
        String::new()
    } else {
        format!(" {name}={value}")
    }
}

fn usage_summary(path: &Path) -> String {
    if !is_regular_follow(path) {
        return String::new();
    }
    // Token classes bill at very different rates (cache writes 1.25x, cache
    // reads 0.1x); summing them reads as spend an order of magnitude too
    // high, so keep them separate: fresh in / cache write / cache read / out.
    let filter = concat!(
        "\", \\(.input_tokens) in / \\(.cache_creation_tokens) cw / ",
        "\\(.cache_read_tokens) cr / \\(.output_tokens) out tok (\\(.model))\"",
    );
    Command::new("jq")
        .args(["-r", filter])
        .arg(path)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .trim_end()
                .to_string()
        })
        .unwrap_or_default()
}

fn command_success(command: &mut Command) -> Result<bool> {
    command
        .status()
        .map(|status| status.success())
        .map_err(|error| format!("run {command:?}: {error}"))
}

fn require_success(status: ExitStatus, action: &str) -> Result<()> {
    if status.success() {
        Ok(())
    } else {
        Err(format!("{action} exited {status}"))
    }
}

fn deadline_decision(
    now: u64,
    last_progress: u64,
    last_heartbeat: u64,
    stall_timeout: u64,
    hard_deadline: u64,
    was_requeued: bool,
) -> Option<TaskStatus> {
    if now >= hard_deadline {
        Some(TaskStatus::Capped)
    } else if now.saturating_sub(last_progress) >= stall_timeout {
        Some(if last_heartbeat == 0 && !was_requeued {
            TaskStatus::Requeue
        } else {
            TaskStatus::Stalled
        })
    } else {
        None
    }
}

fn exit_status(mut value: &[u8]) -> TaskStatus {
    while let Some(stripped) = value.strip_suffix(b"\n") {
        value = stripped;
    }
    if value == b"0" {
        TaskStatus::Done
    } else {
        TaskStatus::Failed
    }
}

trait IoContext<T> {
    fn context(self, message: &str) -> Result<T>;
    fn with_context<F: FnOnce() -> String>(self, message: F) -> Result<T>;
}

impl<T> IoContext<T> for std::io::Result<T> {
    fn context(self, message: &str) -> Result<T> {
        self.map_err(|error| format!("{message}: {error}"))
    }

    fn with_context<F: FnOnce() -> String>(self, message: F) -> Result<T> {
        self.map_err(|error| format!("{}: {error}", message()))
    }
}

fn main() {
    let result = Config::from_env().and_then(|config| Dispatcher::new(config).run());
    if let Err(error) = result {
        eprintln!("agent-dispatcher: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
struct Fixture {
    root: PathBuf,
}

#[cfg(test)]
impl Fixture {
    fn new() -> Result<Self> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let serial = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = env::temp_dir().join(format!(
            "agent-dispatcher-test-{}-{}-{serial}",
            std::process::id(),
            unix_now()
        ));
        fs::create_dir(&root).context("create dispatcher fixture")?;
        Ok(Self { root })
    }

    fn config(&self) -> Result<Config> {
        let tasks = self.root.join("tasks");
        for path in [
            tasks.join("queue"),
            tasks.join("running/worker"),
            tasks.join("done"),
            tasks.join("failed"),
            tasks.join("rejected"),
            tasks.join("cancel"),
            tasks.join("guidance/worker"),
            tasks.join("live"),
            tasks.join("steer"),
            tasks.join("answers"),
            self.root.join("work"),
            self.root.join("creds"),
        ] {
            fs::create_dir_all(path).context("create fixture directory")?;
        }
        let claude = self.root.join("claude-token");
        let codex = self.root.join("codex-auth.json");
        let openrouter = self.root.join("openrouter-key");
        fs::write(&claude, "secret").context("write fixture credential")?;
        fs::write(&codex, "{}").context("write fixture credential")?;
        fs::write(&openrouter, "secret").context("write fixture credential")?;
        Ok(Config {
            tasks,
            worker: "worker".into(),
            work: self.root.join("work"),
            creds: self.root.join("creds"),
            claude_token: claude,
            codex_auth: codex,
            openrouter_key: Some(openrouter),
            readers: "users".into(),
            stall_timeout: 120,
            warm_max_age: 7200,
            task_timeout: 21_600,
            exchange_max_bytes: 1024,
            context_max_bytes: 1024,
        })
    }
}

#[cfg(test)]
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[cfg(test)]
fn self_test() -> Result<()> {
    let fixture = Fixture::new()?;
    let config = fixture.config()?;
    let dispatcher = Dispatcher::new(config.clone());
    let prompt = config.queue().join("stable-key.md");
    fs::write(
        &prompt,
        "---\nagent: codex\nmodel: gpt-5\ntimeout: 30\n---\nwork\n",
    )
    .context("write claim fixture")?;
    fs::write(
        config.queue().join("stable-key.context.tar.zst"),
        b"context",
    )
    .context("write context fixture")?;
    let claim = dispatcher
        .claim_next()?
        .ok_or_else(|| "fixture did not claim a task".to_string())?;
    if claim.id != "stable-key" || claim.context.is_none() {
        return Err("claim did not preserve the task key and context pairing".into());
    }
    fs::write(config.cancel_spool().join("stable-key"), b"")
        .context("write cancellation fixture")?;
    if !dispatcher.pending_cancel(&claim)? {
        return Err("pending cancellation was not detected before dispatch".into());
    }

    let malformed = config.queue().join("linked.md");
    std::os::unix::fs::symlink("missing", &malformed).context("create symlink fixture")?;
    if dispatcher.claim_next()?.is_some() || !exists_any(&config.rejected().join("linked.md")) {
        return Err("symlink queue entry was not rejected".into());
    }

    let metadata = TaskMetadata::read(&claim.prompt, config.task_timeout)?;
    if !matches!(
        select_credential(&config, &metadata)?,
        Credential::File {
            name: "codex-auth.json",
            ..
        }
    ) {
        return Err("credential selector chose the wrong implementation credential".into());
    }
    let verify_prompt = fixture.root.join("verify.md");
    fs::write(
        &verify_prompt,
        "---\nagent: verify\nmodel: fixed\n---\nverify\n",
    )
    .context("write verifier fixture")?;
    if TaskMetadata::read(&verify_prompt, config.task_timeout).is_ok() {
        return Err("retired loop-era verify agent was accepted".into());
    }

    if deadline_decision(120, 0, 0, 120, 1000, false) != Some(TaskStatus::Requeue)
        || deadline_decision(120, 0, 0, 120, 1000, true) != Some(TaskStatus::Stalled)
        || deadline_decision(120, 0, 1, 120, 1000, false) != Some(TaskStatus::Stalled)
        || deadline_decision(1000, 999, 1, 120, 1000, false) != Some(TaskStatus::Capped)
        || deadline_decision(1000, 0, 0, 120, 1000, false) != Some(TaskStatus::Capped)
    {
        return Err("timeout/stall decisions changed".into());
    }
    println!("agent dispatcher self-test passed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_fixture() {
        self_test().unwrap();
    }

    #[test]
    fn malformed_frontmatter_is_rejected() {
        let fixture = Fixture::new().unwrap();
        let prompt = fixture.root.join("prompt.md");
        fs::write(
            &prompt,
            "---\nagent: co dex;$PATH\nmodel: model with spaces\ntimeout: 999999\n---\nbody\n",
        )
        .unwrap();
        assert!(TaskMetadata::read(&prompt, 100).is_err());
        fs::write(
            &prompt,
            "---\nagent: codex\nmodel: gpt-5\ntimeout: 999999\n---\nbody\n",
        )
        .unwrap();
        assert_eq!(TaskMetadata::read(&prompt, 100).unwrap().timeout, 100);
        fs::write(&prompt, "---\nagent: codex\nmodel: gpt-5\nbody\n").unwrap();
        assert!(TaskMetadata::read(&prompt, 100).is_err());
    }

    #[test]
    fn context_symlink_rejects_the_claim() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        fs::write(config.queue().join("unsafe.md"), "prompt").unwrap();
        std::os::unix::fs::symlink("missing", config.queue().join("unsafe.context.tar.zst"))
            .unwrap();
        let dispatcher = Dispatcher::new(config.clone());
        assert!(dispatcher.claim_next().unwrap().is_none());
        assert!(exists_any(&config.rejected().join("unsafe.md")));
        assert!(!exists_any(
            &config.running().join("unsafe.context.tar.zst")
        ));
    }

    #[test]
    fn oversized_prompt_is_rejected_with_its_context() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        fs::write(
            config.queue().join("oversized.md"),
            vec![b'x'; PROMPT_MAX_BYTES as usize + 1],
        )
        .unwrap();
        fs::write(config.queue().join("oversized.context.tar.zst"), "context").unwrap();
        let dispatcher = Dispatcher::new(config.clone());

        assert!(dispatcher.claim_next().unwrap().is_none());
        assert!(exists_any(&config.rejected().join("oversized.md")));
        assert!(!exists_any(
            &config.queue().join("oversized.context.tar.zst")
        ));
    }

    #[test]
    fn queue_claims_oldest_task_before_lexicographic_name() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        let older = config.queue().join("zzz-older.md");
        let newer = config.queue().join("aaa-newer.md");
        fs::write(&older, "prompt").unwrap();
        fs::write(&newer, "prompt").unwrap();
        File::options()
            .write(true)
            .open(&older)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(1)))
            .unwrap();
        File::options()
            .write(true)
            .open(&newer)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(2)))
            .unwrap();

        let task = Dispatcher::new(config).claim_next().unwrap().unwrap();
        assert_eq!(task.id, "zzz-older");
    }

    #[test]
    fn credential_selection_fails_closed() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        let invalid = TaskMetadata {
            agent: Agent::Opencode,
            model: "other/model".into(),
            effort: String::new(),
            guidance: String::new(),
            timeout: 1,
        };
        assert!(select_credential(&config, &invalid).is_err());
    }

    #[test]
    fn questions_route_to_cockpit_or_get_the_stock_answer() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        let dispatcher = Dispatcher::new(config.clone());
        let live = config.live_root().join("job");
        fs::create_dir_all(&live).unwrap();
        fs::write(config.work.join("question-1.md"), "stuck on X").unwrap();
        let task = ClaimedTask {
            id: "job".into(),
            prompt: config.work.join("question-1.md"),
            context: None,
        };
        let mut seen = BTreeSet::new();

        // No cockpit routing: the stock answer lands in the exchange at once,
        // and nothing surfaces in the live view. (The cockpit branch chowns
        // to root, so it is exercised in production, not here.)
        let metadata = TaskMetadata::rejected(60);
        dispatcher
            .relay_questions(&task, &metadata, &live, &mut seen)
            .unwrap();
        assert_eq!(
            fs::read(config.work.join("answer-1.md")).unwrap(),
            NO_ADVISOR_ANSWER
        );
        assert!(!live.join("question-1.md").exists());
        // Idempotent: a second pass neither rewrites nor re-logs.
        dispatcher
            .relay_questions(&task, &metadata, &live, &mut seen)
            .unwrap();
        assert!(seen.contains(&1));
    }

    #[test]
    fn exit_code_is_total_over_untrusted_bytes() {
        assert_eq!(exit_status(b"0\n\n"), TaskStatus::Done);
        assert_eq!(exit_status(b"1\n"), TaskStatus::Failed);
        assert_eq!(exit_status(&[0xff]), TaskStatus::Failed);
    }

    #[test]
    fn restart_keeps_published_results_terminal() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        let dispatcher = Dispatcher::new(config.clone());
        fs::write(config.running().join("finished.md"), "prompt").unwrap();
        fs::write(config.running().join("finished.context.tar.zst"), "context").unwrap();
        fs::create_dir(config.tasks.join("done/finished")).unwrap();
        fs::write(config.cancel_spool().join("finished"), "cancel").unwrap();
        fs::create_dir(config.live_root().join("finished")).unwrap();

        dispatcher.requeue_stranded().unwrap();

        assert!(!exists_any(&config.running().join("finished.md")));
        assert!(!exists_any(
            &config.running().join("finished.context.tar.zst")
        ));
        assert!(!exists_any(&config.queue().join("finished.md")));
        assert!(!exists_any(&config.cancel_spool().join("finished")));
        assert!(!exists_any(&config.live_root().join("finished")));
    }

    #[test]
    fn startup_removes_only_its_partial_results() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        let dispatcher = Dispatcher::new(config.clone());
        let own = config.tasks.join("failed/.task.worker.tmp");
        let other = config.tasks.join("failed/.task.other.tmp");
        fs::create_dir(&own).unwrap();
        fs::create_dir(&other).unwrap();

        dispatcher.remove_partial_results().unwrap();

        assert!(!exists_any(&own));
        assert!(exists_any(&other));
    }

    #[test]
    fn terminal_task_ids_are_idempotent() {
        let fixture = Fixture::new().unwrap();
        let config = fixture.config().unwrap();
        fs::create_dir(config.tasks.join("done/already-done")).unwrap();
        fs::write(config.queue().join("already-done.md"), "prompt").unwrap();
        fs::write(
            config.queue().join("already-done.context.tar.zst"),
            "context",
        )
        .unwrap();
        let dispatcher = Dispatcher::new(config.clone());

        assert!(dispatcher.claim_next().unwrap().is_none());
        assert!(!exists_any(&config.queue().join("already-done.md")));
        assert!(!exists_any(
            &config.queue().join("already-done.context.tar.zst")
        ));
    }

    #[test]
    fn bounded_copy_rejects_links_oversize_and_existing_destinations() {
        let fixture = Fixture::new().unwrap();
        let dispatcher = Dispatcher::new(fixture.config().unwrap());
        let source = fixture.root.join("source");
        let destination = fixture.root.join("destination");
        fs::write(&source, "safe").unwrap();
        dispatcher
            .safe_transfer(&source, &destination, 4, 0o640)
            .unwrap();
        assert_eq!(fs::read(&destination).unwrap(), b"safe");

        assert!(
            dispatcher
                .safe_transfer(&source, &destination, 4, 0o640)
                .is_err()
        );
        let linked = fixture.root.join("linked-source");
        std::os::unix::fs::symlink(&source, &linked).unwrap();
        assert!(
            dispatcher
                .safe_transfer(&linked, &fixture.root.join("linked-copy"), 4, 0o640)
                .is_err()
        );
        assert!(
            dispatcher
                .safe_transfer(&source, &fixture.root.join("oversized-copy"), 3, 0o640)
                .is_err()
        );

        let wrong_owner = fixture.root.join("wrong-owner-copy");
        let source_uid = fs::metadata(&source).unwrap().uid();
        assert!(
            dispatcher
                .safe_transfer_owned(
                    &source,
                    &wrong_owner,
                    4,
                    0o640,
                    Some(source_uid.saturating_add(1)),
                )
                .is_err()
        );

        let fifo = fixture.root.join("fifo-source");
        let fifo_path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) }, 0);
        assert!(
            dispatcher
                .safe_transfer(&fifo, &fixture.root.join("fifo-copy"), 4, 0o640)
                .is_err()
        );
    }
}

// ship-costs — the ledger. Answers "what would this month's AI usage have
// cost at API rates?" across every pool the ship spends from. See
// ship-costs.mod.nix for the full contract; this is a faithful port of the
// Python original, output-compatible line for line.
//
// Token counts are real (recorded by each tool); USD figures are
// API-EQUIVALENT — subscriptions bill flat, so this is an opportunity-cost
// lens, not an invoice. A recorded cost (opencode metered rows) and a
// pricing-table estimate are alternatives, never additive.

use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde_json::Value;
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const fn build_default(value: Option<&'static str>, default: &'static str) -> &'static str {
    match value {
        Some(value) => value,
        None => default,
    }
}

const OPENROUTER_KEY_FILE: &str = build_default(option_env!("SHIP_OPENROUTER_KEY_FILE"), "");
const SQLITE3: &str = build_default(option_env!("SHIP_SQLITE3"), "sqlite3");
const CURL: &str = build_default(option_env!("SHIP_CURL"), "curl");

// ($/MTok) prefix-matched, first hit wins: (in, out, cache_read,
// cache_write_5m, cache_write_1h). Update when vendors reprice.
const PRICING: &[(&str, [f64; 5])] = &[
    ("claude-fable-5", [10.0, 50.0, 1.0, 12.5, 20.0]),
    ("claude-opus", [5.0, 25.0, 0.5, 6.25, 10.0]),
    ("claude-sonnet", [3.0, 15.0, 0.3, 3.75, 6.0]),
    ("claude-haiku", [1.0, 5.0, 0.1, 1.25, 2.0]),
    ("gpt-5.6-sol", [5.0, 30.0, 0.5, 0.0, 0.0]),
    ("gpt-5.5", [5.0, 30.0, 0.5, 0.0, 0.0]),
    ("gpt-5.6-terra", [2.5, 15.0, 0.25, 0.0, 0.0]),
    ("gpt-5.4", [2.5, 15.0, 0.25, 0.0, 0.0]),
    ("gpt-5.6-luna", [1.0, 6.0, 0.1, 0.0, 0.0]),
    ("gpt-", [5.0, 30.0, 0.5, 0.0, 0.0]), // unknown gpt: price like Sol, flagged
];

fn rates(model: &str) -> Option<&'static [f64; 5]> {
    let name = model.rsplit('/').next().unwrap_or(model);
    PRICING
        .iter()
        .find(|(prefix, _)| name.starts_with(prefix))
        .map(|(_, rate)| rate)
}

fn pool_of(model: &str) -> &'static str {
    let m = model.to_lowercase();
    if m.starts_with("local/") {
        "local"
    } else if m.starts_with("openrouter/") {
        "openrouter"
    } else if m.contains("claude") {
        "claude"
    } else if m.contains("gpt") || m.starts_with("openai/") {
        "chatgpt"
    } else {
        "other"
    }
}

// One usage event: cw5/cw1 are Anthropic 5m/1h cache writes; non-Anthropic
// cache reads land in cr. `cost` is a tool-recorded dollar figure
// (opencode metered rows only).
#[derive(Clone, Debug, Default)]
struct Tokens {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write_5m: i64,
    cache_write_1h: i64,
    cost: f64,
}

struct Event {
    ts: DateTime<Utc>,
    model: String,
    source: String,
    tokens: Tokens,
}

fn cost_usd(model: &str, tokens: &Tokens) -> f64 {
    if pool_of(model) == "local" {
        return 0.0;
    }
    let Some([i, o, cr, cw5, cw1]) = rates(model) else {
        return tokens.cost;
    };
    (tokens.input as f64 * i
        + tokens.output as f64 * o
        + tokens.cache_read as f64 * cr
        + tokens.cache_write_5m as f64 * cw5
        + tokens.cache_write_1h as f64 * cw1)
        / 1e6
}

// ---- small helpers ---------------------------------------------------------

fn int(value: &Value, field: &str) -> i64 {
    value.get(field).and_then(Value::as_i64).unwrap_or(0)
}

fn text<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value.get(field).and_then(Value::as_str)
}

/// Python `datetime.fromisoformat` (as used here): offset-aware datetimes
/// only; naive timestamps would poison window comparisons, so None.
fn parse_ts_aware(raw: &str) -> Option<DateTime<Utc>> {
    let cooked = raw.replace('Z', "+00:00");
    DateTime::parse_from_rfc3339(&cooked)
        .ok()
        .map(|ts| ts.with_timezone(&Utc))
}

/// The tolerant variant for the OpenRouter activity rows: naive datetimes
/// and bare dates are taken as UTC.
fn parse_ts_lenient(raw: &str) -> Option<DateTime<Utc>> {
    if let Some(ts) = parse_ts_aware(raw) {
        return Some(ts);
    }
    for format in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(raw, format) {
            return Some(Utc.from_utc_datetime(&naive));
        }
    }
    NaiveDate::parse_from_str(raw, "%Y-%m-%d")
        .ok()
        .and_then(|date| date.and_hms_opt(0, 0, 0))
        .map(|naive| Utc.from_utc_datetime(&naive))
}

/// Recursive *.suffix files under root, symlinks followed like glob's.
fn walk(root: &Path, suffix: &str, into: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    let mut paths: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
    paths.sort();
    for path in paths {
        if path.is_dir() {
            walk(&path, suffix, into);
        } else if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(suffix))
        {
            into.push(path);
        }
    }
}

/// One JSON value per line; invalid UTF-8 is replaced rather than aborting
/// the file (Python read with errors="replace").
fn json_lines(path: &Path) -> Vec<Value> {
    let Ok(bytes) = fs::read(path) else {
        return Vec::new();
    };
    String::from_utf8_lossy(&bytes)
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

/// Python truthiness for JSON containers: null, {}, "" and 0 are all falsy.
fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Object(map) => !map.is_empty(),
        Value::Array(items) => !items.is_empty(),
        Value::String(text) => !text.is_empty(),
        Value::Number(number) => number.as_f64() != Some(0.0),
        Value::Bool(flag) => *flag,
    }
}

// ---- usage stores ----------------------------------------------------------

fn iter_claude(home: &Path, events: &mut Vec<Event>) {
    let mut seen = std::collections::BTreeSet::new();
    let mut transcripts = Vec::new();
    walk(&home.join(".claude/projects"), ".jsonl", &mut transcripts);
    for path in transcripts {
        for entry in json_lines(&path) {
            if text(&entry, "type") != Some("assistant") {
                continue;
            }
            let message = entry.get("message").cloned().unwrap_or(Value::Null);
            let Some(usage) = message.get("usage").filter(|u| truthy(u)) else {
                continue;
            };
            let key = (
                text(&entry, "requestId").map(String::from),
                text(&message, "id").map(String::from),
            );
            if key != (None, None) {
                // unkeyed entries can't dedup
                if !seen.insert(key) {
                    continue;
                }
            }
            let creation = usage.get("cache_creation").filter(|c| truthy(c));
            let (cw5, cw1) = match creation {
                Some(nested) => (
                    int(nested, "ephemeral_5m_input_tokens"),
                    int(nested, "ephemeral_1h_input_tokens"),
                ),
                // older entries: only the total, price as 5m
                None => (int(usage, "cache_creation_input_tokens"), 0),
            };
            let Some(ts) = text(&entry, "timestamp").and_then(parse_ts_aware) else {
                continue;
            };
            events.push(Event {
                ts,
                model: text(&message, "model").unwrap_or("unknown").to_string(),
                source: "cockpit claude".into(),
                tokens: Tokens {
                    input: int(usage, "input_tokens"),
                    output: int(usage, "output_tokens"),
                    cache_read: int(usage, "cache_read_input_tokens"),
                    cache_write_5m: cw5,
                    cache_write_1h: cw1,
                    cost: 0.0,
                },
            });
        }
    }
}

fn iter_codex(home: &Path, events: &mut Vec<Event>) {
    // total_token_usage is cumulative per session file: emit the DELTA at
    // each token_count event, attributed to the model in force, so sessions
    // spanning a window boundary split correctly. A decrease means a fresh
    // counter (new session in-file); treat the new value as its own delta.
    let mut sessions = Vec::new();
    walk(&home.join(".codex/sessions"), ".jsonl", &mut sessions);
    for path in sessions {
        let mut model = "unknown".to_string();
        let mut previous = [0i64; 3]; // input, cached_input, output
        for entry in json_lines(&path) {
            let payload = entry.get("payload").cloned().unwrap_or(Value::Null);
            if text(&entry, "type") == Some("turn_context") {
                if let Some(name) = text(&payload, "model").filter(|name| !name.is_empty()) {
                    model = name.to_string();
                }
            } else if text(&entry, "type") == Some("event_msg")
                && text(&payload, "type") == Some("token_count")
            {
                let info = payload.get("info").cloned().unwrap_or(Value::Null);
                let Some(total) = info.get("total_token_usage").filter(|t| truthy(t)) else {
                    continue;
                };
                let Some(ts) = text(&entry, "timestamp").and_then(parse_ts_aware) else {
                    continue;
                };
                let current = [
                    int(total, "input_tokens"),
                    int(total, "cached_input_tokens"),
                    int(total, "output_tokens"),
                ];
                if current.iter().zip(&previous).any(|(c, p)| c < p) {
                    previous = [0; 3];
                }
                let delta = [
                    current[0] - previous[0],
                    current[1] - previous[1],
                    current[2] - previous[2],
                ];
                previous = current;
                if delta.iter().any(|d| *d != 0) {
                    events.push(Event {
                        ts,
                        model: model.clone(),
                        source: "cockpit codex".into(),
                        tokens: Tokens {
                            input: delta[0] - delta[1],
                            output: delta[2],
                            cache_read: delta[1],
                            ..Tokens::default()
                        },
                    });
                }
            }
        }
    }
}

fn iter_opencode(home: &Path, events: &mut Vec<Event>) {
    let store = home.join(".local/share/opencode");
    let Ok(entries) = fs::read_dir(&store) else {
        return;
    };
    let mut databases: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(".db"))
        })
        .collect();
    databases.sort();
    for database in databases {
        let Ok(output) = Command::new(SQLITE3)
            .args(["-readonly", "-json"])
            .arg(&database)
            .arg("select data from message")
            .stdin(Stdio::null())
            .output()
        else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let Ok(rows) = serde_json::from_slice::<Value>(&output.stdout) else {
            continue;
        };
        for row in rows.as_array().map(Vec::as_slice).unwrap_or(&[]) {
            let Some(message) = text(row, "data").and_then(|data| {
                serde_json::from_str::<Value>(data).ok()
            }) else {
                continue;
            };
            if text(&message, "role") != Some("assistant") {
                continue;
            }
            let Some(tokens) = message.get("tokens").filter(|t| truthy(t)) else {
                continue;
            };
            let Some(created) = message
                .get("time")
                .and_then(|time| time.get("created"))
                .and_then(Value::as_f64)
                .filter(|ms| *ms != 0.0)
            else {
                continue;
            };
            let Some(ts) = Utc.timestamp_millis_opt(created as i64).single() else {
                continue;
            };
            let cache = tokens.get("cache").cloned().unwrap_or(Value::Null);
            events.push(Event {
                ts,
                model: format!(
                    "{}/{}",
                    text(&message, "providerID").unwrap_or("?"),
                    text(&message, "modelID").unwrap_or("unknown")
                ),
                source: "cockpit opencode".into(),
                tokens: Tokens {
                    input: int(tokens, "input"),
                    output: int(tokens, "output") + int(tokens, "reasoning"),
                    cache_read: int(&cache, "read"),
                    cache_write_5m: int(&cache, "write"),
                    cache_write_1h: 0,
                    cost: message.get("cost").and_then(Value::as_f64).unwrap_or(0.0),
                },
            });
        }
    }
}

fn iter_fleet(events: &mut Vec<Event>) {
    for category in ["done", "failed"] {
        let root = PathBuf::from("/var/lib/agents/tasks").join(category);
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        let mut tasks: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
        tasks.sort();
        for task in tasks {
            let path = task.join("usage.json");
            let Ok(metadata) = fs::metadata(&path) else {
                continue;
            };
            let Ok(modified) = metadata.modified() else {
                continue;
            };
            let Ok(contents) = fs::read_to_string(&path) else {
                continue;
            };
            let Ok(usage) = serde_json::from_str::<Value>(&contents) else {
                continue;
            };
            events.push(Event {
                ts: DateTime::<Utc>::from(modified),
                model: text(&usage, "model").unwrap_or("unknown").to_string(),
                source: format!("drone {}", text(&usage, "executor").unwrap_or("?")),
                tokens: Tokens {
                    input: int(&usage, "input_tokens"),
                    output: int(&usage, "output_tokens"),
                    cache_read: int(&usage, "cache_read_tokens"),
                    cache_write_5m: int(&usage, "cache_creation_tokens"),
                    ..Tokens::default()
                },
            });
        }
    }
}

// ---- openrouter exact spend ------------------------------------------------

fn openrouter_exact() -> Option<Vec<Value>> {
    if OPENROUTER_KEY_FILE.is_empty() {
        return None;
    }
    let key = fs::read_to_string(OPENROUTER_KEY_FILE).ok()?;
    let key = key.trim().rsplit('=').next()?.to_string();
    // The key goes through curl's config channel on stdin, never argv.
    let mut curl = Command::new(CURL)
        .args(["-sf", "--max-time", "15", "--config", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    curl.stdin
        .take()?
        .write_all(
            format!(
                "url = \"https://openrouter.ai/api/v1/activity\"\nheader = \"Authorization: Bearer {key}\"\n"
            )
            .as_bytes(),
        )
        .ok()?;
    let output = curl.wait_with_output().ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice::<Value>(&output.stdout)
        .ok()?
        .get("data")?
        .as_array()
        .cloned()
}

// ---- presentation ----------------------------------------------------------

fn terminal_columns() -> usize {
    if let Some(columns) = env::var("COLUMNS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
    {
        return columns;
    }
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0
        && size.ws_col > 0
    {
        return size.ws_col as usize;
    }
    80
}

/// `textwrap.fill`: greedy word wrap to the terminal width.
fn fill(paragraph: &str, columns: usize) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut line = String::new();
    for word in paragraph.split_whitespace() {
        if !line.is_empty() && line.len() + 1 + word.len() > columns {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines.join("\n")
}

fn main() {
    let columns = terminal_columns();
    let narrow = columns < 74;
    let bare = env::args().any(|argument| argument == "--bare");
    let now = Utc::now();
    let month_start = Utc
        .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
        .single()
        .unwrap_or(now);
    let d30_start = now - Duration::days(30);
    let home = PathBuf::from(env::var("HOME").unwrap_or_else(|_| "/".into()));

    let mut events = Vec::new();
    iter_claude(&home, &mut events);
    iter_codex(&home, &mut events);
    iter_opencode(&home, &mut events);
    iter_fleet(&mut events);

    // (pool, model, source) -> aggregated tokens, per window.
    let mut mtd: BTreeMap<(String, String, String), Tokens> = BTreeMap::new();
    let mut d30: BTreeMap<(String, String, String), Tokens> = BTreeMap::new();
    for event in &events {
        for (start, window) in [(month_start, &mut mtd), (d30_start, &mut d30)] {
            if event.ts < start {
                continue;
            }
            let key = (
                pool_of(&event.model).to_string(),
                event.model.clone(),
                event.source.clone(),
            );
            let aggregate = window.entry(key).or_default();
            aggregate.input += event.tokens.input;
            aggregate.output += event.tokens.output;
            aggregate.cache_read += event.tokens.cache_read;
            aggregate.cache_write_5m += event.tokens.cache_write_5m;
            aggregate.cache_write_1h += event.tokens.cache_write_1h;
            aggregate.cost += event.tokens.cost;
        }
    }

    let emit = |line: &str| {
        if narrow {
            println!("{}", fill(line, columns));
        } else {
            println!("{line}");
        }
    };

    // --bare drops the standalone intro paragraph, for embedding under the
    // LEDGER section of the combined `ship` dashboard.
    if !bare {
        emit(&format!(
            "SHIP COSTS — API-equivalent spend (subs bill flat; this is what \
             the same usage would cost at API rates). Ship-side usage only; \
             app chats are invisible. Windows: MTD since {}, rolling 30d.",
            month_start.format("%b %d")
        ));
        println!();
    }

    let pool_order = |pool: &str| match pool {
        "claude" => 0,
        "chatgpt" => 1,
        "openrouter" => 2,
        "local" => 3,
        "other" => 4,
        _ => 9,
    };
    // MTD-only keys can exist on day 31.
    let mut keys: Vec<(String, String, String)> =
        d30.keys().chain(mtd.keys()).cloned().collect();
    keys.sort_by(|left, right| {
        (pool_order(&left.0), &left.1, &left.2).cmp(&(pool_order(&right.0), &right.1, &right.2))
    });
    keys.dedup();

    let header = format!(
        "{:<11}{:<28}{:<18}{:>8}{:>9}{:>9}",
        "POOL", "MODEL", "SOURCE", "TOK(M)", "MTD $", "30D $"
    );
    if !narrow {
        println!("{header}");
        println!("{}", "-".repeat(header.len()));
    }
    let mut totals_mtd: BTreeMap<String, f64> = BTreeMap::new();
    let mut totals_d30: BTreeMap<String, f64> = BTreeMap::new();
    for key in &keys {
        let (pool, model, source) = key;
        let t30 = d30.get(key);
        let tmtd = mtd.get(key);
        let usd30 = t30.map(|tokens| cost_usd(model, tokens)).unwrap_or(0.0);
        let usdmtd = tmtd.map(|tokens| cost_usd(model, tokens)).unwrap_or(0.0);
        *totals_d30.entry(pool.clone()).or_default() += usd30;
        *totals_mtd.entry(pool.clone()).or_default() += usdmtd;
        let sum = t30.or(tmtd).cloned().unwrap_or_default();
        let mtok = (sum.input + sum.output + sum.cache_read + sum.cache_write_5m
            + sum.cache_write_1h) as f64
            / 1e6;
        let star = if rates(model).is_some() || pool == "local" {
            ""
        } else {
            " *"
        };
        let short: String = model.chars().take(27).collect();
        if narrow {
            println!("{pool}/{short} · {source}");
            println!("  {mtok:.1}M tok · MTD ${usdmtd:.2} · 30D ${usd30:.2}{star}");
        } else {
            println!("{pool:<11}{short:<28}{source:<18}{mtok:>8.1}{usdmtd:>9.2}{usd30:>9.2}{star}");
        }
    }
    let mut pools: Vec<&String> = totals_d30.keys().collect();
    pools.sort_by_key(|pool| pool_order(pool));
    let grand_mtd: f64 = totals_mtd.values().sum();
    let grand_d30: f64 = totals_d30.values().sum();
    if narrow {
        println!("{}", "─".repeat(columns));
        for pool in pools {
            println!(
                "{pool:<9} MTD ${:.2} · 30D ${:.2}",
                totals_mtd.get(pool).copied().unwrap_or(0.0),
                totals_d30[pool]
            );
        }
        println!("{:<9} MTD ${grand_mtd:.2} · 30D ${grand_d30:.2}", "ALL");
    } else {
        println!("{}", "-".repeat(header.len()));
        for pool in pools {
            // MODEL(28)+SOURCE(18)+TOK(8) minus len("TOTAL")
            println!(
                "{pool:<11}TOTAL{}{:>9.2}{:>9.2}",
                " ".repeat(49),
                totals_mtd.get(pool).copied().unwrap_or(0.0),
                totals_d30[pool]
            );
        }
        println!("{:<11}{}{grand_mtd:>9.2}{grand_d30:>9.2}", "ALL", " ".repeat(54));
    }
    println!("\n* no pricing entry — token counts real, cost not estimated");

    match openrouter_exact() {
        Some(rows) => {
            println!("\nOPENROUTER (exact, via API):");
            let mut by_model: BTreeMap<String, (f64, f64)> = BTreeMap::new();
            for row in rows {
                let Some(ts) = text(&row, "date").and_then(parse_ts_lenient) else {
                    continue;
                };
                if ts < d30_start {
                    continue;
                }
                let usage = row.get("usage").and_then(Value::as_f64).unwrap_or(0.0);
                let entry = by_model
                    .entry(text(&row, "model").unwrap_or("?").to_string())
                    .or_default();
                entry.0 += usage;
                if ts >= month_start {
                    entry.1 += usage;
                }
            }
            for (model, (u30, umtd)) in by_model {
                if narrow {
                    println!("  {model}");
                    println!("    MTD ${umtd:.2} · 30D ${u30:.2}");
                } else {
                    println!("  {model:<40}{umtd:>9.2}{u30:>9.2}");
                }
            }
        }
        None if !OPENROUTER_KEY_FILE.is_empty() => {
            println!();
            emit(
                "OPENROUTER: key configured but API query failed (see the \
                 above table for opencode-recorded costs).",
            );
        }
        None => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pricing_prefix_match_first_hit_wins() {
        assert_eq!(rates("claude-haiku-4-5-20251001"), Some(&[1.0, 5.0, 0.1, 1.25, 2.0]));
        assert_eq!(rates("openrouter/x/claude-opus-4"), Some(&[5.0, 25.0, 0.5, 6.25, 10.0]));
        assert_eq!(rates("gpt-5.6-sol"), Some(&[5.0, 30.0, 0.5, 0.0, 0.0]));
        // the generic gpt- fallback
        assert_eq!(rates("gpt-99-future"), Some(&[5.0, 30.0, 0.5, 0.0, 0.0]));
        assert_eq!(rates("moonshotai/kimi-k2"), None);
    }

    #[test]
    fn pools_classify_like_python() {
        assert_eq!(pool_of("claude-fable-5"), "claude");
        assert_eq!(pool_of("local/qwen3"), "local");
        assert_eq!(pool_of("openrouter/moonshotai/kimi-k2"), "openrouter");
        assert_eq!(pool_of("gpt-5.6-sol"), "chatgpt");
        assert_eq!(pool_of("openai/o3"), "chatgpt");
        assert_eq!(pool_of("mystery"), "other");
    }

    #[test]
    fn cost_rules_are_alternatives_never_additive() {
        let tokens = Tokens {
            input: 1_000_000,
            output: 1_000_000,
            cache_read: 1_000_000,
            cache_write_5m: 1_000_000,
            cache_write_1h: 1_000_000,
            cost: 42.0,
        };
        // Priced model: table only, recorded cost ignored.
        assert_eq!(cost_usd("claude-haiku-4-5", &tokens), 1.0 + 5.0 + 0.1 + 1.25 + 2.0);
        // Unpriced model: recorded cost only.
        assert_eq!(cost_usd("openrouter/kimi", &tokens), 42.0);
        // Local: always free.
        assert_eq!(cost_usd("local/qwen3", &tokens), 0.0);
    }

    #[test]
    fn aware_timestamps_only_for_transcripts() {
        assert!(parse_ts_aware("2026-07-19T10:59:52.123Z").is_some());
        assert!(parse_ts_aware("2026-07-19T10:59:52+02:00").is_some());
        assert!(parse_ts_aware("2026-07-19T10:59:52").is_none()); // naive
        assert!(parse_ts_aware("2026-07-19").is_none());
        assert!(parse_ts_lenient("2026-07-19").is_some());
        assert!(parse_ts_lenient("2026-07-19T10:59:52").is_some());
    }

    #[test]
    fn wrap_matches_textwrap_shape() {
        assert_eq!(fill("a b c", 3), "a b\nc");
        assert_eq!(fill("word", 2), "word"); // overlong words stay whole
    }
}

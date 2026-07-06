# Claude Code global instructions (~/.claude/CLAUDE.md), versioned here
# instead of hand-edited in place. Only this config file is managed —
# everything else under ~/.claude (memory, transcripts, credentials) is
# mutable state Claude writes to live and must stay unmanaged. Gated on
# isDesktop to match where claude-code is installed (packages-dev-extras).
{
  flake.homeModules.claude =
    { lib, osConfig, ... }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf osConfig.isDesktop {
        home.file.".claude/CLAUDE.md" = {
          # Adopt the pre-existing hand-written file on first switch.
          force = true;
          text = ''
            # Global instructions

            ## Commits

            Never add Co-Authored-By, Claude-Session, "Generated with Claude Code", or any similar trailers/attribution lines to commit messages or PR bodies. Plain messages only.

            ## Permission denials are vetoes

            A denial vetoes the *outcome*, not just the specific tool call. Never achieve the same effect through a different tool (sed/bash instead of a denied Edit, a wrapper script instead of a denied command, etc.). A denial usually means the user dislikes the action or thinks you're on a lost path — but it can also be a misclick while switching windows. Either way the response is the same: stop, explain what you were trying to do and why, and let the user decide — they'll re-approve if it was a misclick. Pass this rule along in the prompt of any subagent that will take actions.

            ## Autonomy

            Keep going by default. Stop to ask only when something is hard to undo (destructive actions, force-pushes, publishing), a real change in scope from what was asked, or a decision only the user can make (taste, priorities). Everything else — read-only work, research, reversible edits within the agreed task — just do it and report. Never ask permission for read-only work under any circumstances.

            ## Verification before "done"

            Before reporting a task complete, show the proof: the build output, the test run, the command result — whatever demonstrates it actually works, not just that the edit was made. If a step wasn't verified (couldn't run it, needs a reboot, needs hardware), say so explicitly instead of folding it into "done". This applies to subagents too: require proof in their prompts, and don't relay their "done" as verified unless it comes with evidence.

            ## Economics

            Budget and usage limits are real constraints, and both plans (Claude, ChatGPT) are subscription pools with caps — so cost is opportunity cost: which pool a task drains, and how scarce that pool is. Fable-time is the scarcest, highest-value capacity; spend it on judgment-dense work (planning, debugging, root-cause analysis, final review) and push everything else down.

            Capability is a floor, not a dial: pick the cheapest model that clears the task's bar WITH MARGIN. Never trade capability for cost — a failed cheap attempt costs the redo plus review plus latency, which is worse than paying up front. When unsure which side of the bar a task is on, go up a tier. If a model fails a task, escalate — never retry at the same tier. Delegate freely where output is cheap to verify (builds, tests, reviewable diffs); keep work where verification costs as much as doing it.

            Targets, by capability: haiku (mechanical, fully-specified), sonnet (routine implementation from a clear spec), GPT-5.5 via Codex (substantial standalone coding, independent reviews, second opinions — bills to the ChatGPT pool, much better cost/performance than Fable; always request it explicitly, e.g. `codex exec -m gpt-5.5`, and never edit `~/.codex/`), opus (strong-model work that must run inside the Claude agent loop with session context). Judgment over rules throughout.
          '';
        };
      };
    };
}

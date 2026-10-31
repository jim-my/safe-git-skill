# Keep this repo in step with agent-skills/safe-git in dotfiles, the source of truth.
# `just ready` leaves the branch verified; pushing stays a separate, manual step.

default:
    @just --list

# Export safe-git from dotfiles HEAD, test the export, mirror it here, and commit
sync:
    scripts/sync-from-dotfiles.py
    git add -A
    git diff --cached --quiet || git commit -qm "Sync safe-git from dotfiles $(cut -c1-12 SYNCED_FROM)"

# Run the safe-git suite and the sync script's tests
test:
    bash test/run.sh </dev/null
    python3 scripts/test_sync_from_dotfiles.py

# Install committed HEAD from a fresh clone with a fake HOME and no skillbin
smoke:
    scripts/smoke-from-clone.sh

# Sync from dotfiles, then run every check
ready: sync test smoke

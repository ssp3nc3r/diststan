#!/bin/bash
# Set up a self-healing, Tailscale-addressed auto-mount of WORK_A on a CLIENT mac.
# Uses Apple ID / Continuity SSO (no stored password). User-owned; no sudo.
set +e
SRV="talkingspoons.tail0f4358.ts.net"
LABEL="com.scottspencer.worka-mount"
UID_=$(id -u)
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents"

cat > "$HOME/.local/bin/diststan-mount-worka.sh" <<'SH'
#!/bin/sh
SRV="talkingspoons.tail0f4358.ts.net"
MP="/Volumes/WORK_A"
# Already mounted at the canonical path? nothing to do.
mount | grep -q " on ${MP} (smbfs" && exit 0
# Otherwise mount the Tailscale share (SSO); with MP free it lands at /Volumes/WORK_A.
open "smb://${SRV}/WORK_A"
SH
chmod +x "$HOME/.local/bin/diststan-mount-worka.sh"

cat > "$HOME/Library/LaunchAgents/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>$HOME/.local/bin/diststan-mount-worka.sh</string></array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>120</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST

# Clean up the duplicate mount and free /Volumes/WORK_A so the agent can claim it.
diskutil unmount force /Volumes/WORK_A-1 >/dev/null 2>&1
diskutil unmount force /Volumes/WORK_A   >/dev/null 2>&1

launchctl bootout   "gui/$UID_/$LABEL" 2>/dev/null
launchctl bootstrap "gui/$UID_" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>&1
launchctl kickstart -k "gui/$UID_/$LABEL" 2>&1
sleep 6
echo "--- mounts ---"; mount | grep -i work_a || echo "(none)"
if ls /Volumes/WORK_A/Projects/sas/diststan >/dev/null 2>&1; then
  echo "RESULT: OK (/Volumes/WORK_A live via agent)"
else
  echo "RESULT: NOT MOUNTED"
fi

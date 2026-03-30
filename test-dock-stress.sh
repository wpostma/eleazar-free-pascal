#!/bin/bash
#
# Dock stress test — provoke the autosizing storm by rapidly
# undocking, resizing, docking, and switching layouts.
#
# Usage:
#   bash test-dock-stress.sh              # default: 5 rounds
#   bash test-dock-stress.sh 20           # 20 rounds
#   bash test-dock-stress.sh 5 4748       # 5 rounds, port 4748
#
set -euo pipefail

ROUNDS="${1:-5}"
PORT="${2:-4747}"
HOST="127.0.0.1"

send() {
  python3 -c "
import socket, json, sys
s = socket.socket(); s.settimeout(30); s.connect(('$HOST', $PORT))
s.sendall((json.dumps($1) + '\n').encode())
buf = b''
while b'\n' not in buf:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
r = json.loads(buf.split(b'\n')[0])
res = r.get('result', r)
err = r.get('error', res.get('error', ''))
if err:
    print(f'  ERROR: {err}', file=sys.stderr)
    sys.exit(1)
s.close()
" 2>&1
}

send_quiet() {
  send "$1" > /dev/null 2>&1 || true
}

echo "=== Dock Stress Test ==="
echo "Rounds: $ROUNDS  Port: $PORT"
echo ""

# Verify connection
echo "Connecting..."
send '{"id":0,"cmd":"ping"}'
echo ""

# Snapshot baseline
BASELINE=$(python3 -c "
import socket, json
s = socket.socket(); s.settimeout(5); s.connect(('$HOST', $PORT))
s.sendall(b'{\"id\":1,\"cmd\":\"stats\"}\n')
buf = b''
while b'\n' not in buf: buf += s.recv(4096)
r = json.loads(buf.split(b'\n')[0])
print(r.get('result',{}).get('total_pushed', 0))
s.close()
")
echo "Baseline events: $BASELINE"

# Get available desktops
echo "Fetching desktop list..."
DESKTOPS=$(python3 -c "
import socket, json
s = socket.socket(); s.settimeout(5); s.connect(('$HOST', $PORT))
s.sendall(b'{\"id\":1,\"cmd\":\"list_desktops\"}\n')
buf = b''
while b'\n' not in buf: buf += s.recv(65536)
r = json.loads(buf.split(b'\n')[0])
desks = r.get('result',{}).get('desktops',[])
compatible = [d['name'] for d in desks if d.get('compatible')]
print(' '.join(compatible))
s.close()
")
echo "Compatible desktops: $DESKTOPS"
echo ""

# Forms to undock/dock
FORMS="ObjectInspectorDlg MessagesView CodeExplorerView"
SIDES="left right top bottom"

START_TIME=$(date +%s)

for ROUND in $(seq 1 "$ROUNDS"); do
  echo "--- Round $ROUND/$ROUNDS ---"

  # Phase 1: Undock forms one by one
  echo "  Undocking..."
  for FORM in $FORMS; do
    send_quiet "{\"id\":1,\"cmd\":\"undock\",\"path\":\"$FORM\"}"
    sleep 0.2
  done

  # Phase 2: Resize MainIDE a few times
  echo "  Resizing MainIDE..."
  for W in 2000 2400 1600 3000 2880; do
    send_quiet "{\"id\":1,\"cmd\":\"resize\",\"path\":\"MainIDE\",\"w\":$W,\"h\":1200}"
    sleep 0.1
  done

  # Phase 3: Dock forms back in different arrangements
  echo "  Redocking..."
  SIDE_IDX=0
  for FORM in $FORMS; do
    SIDE=$(echo "$SIDES" | cut -d' ' -f$(( (SIDE_IDX % 4) + 1 )))
    send_quiet "{\"id\":1,\"cmd\":\"dock\",\"path\":\"$FORM\",\"target\":\"SourceNotebook\",\"side\":\"$SIDE\"}"
    SIDE_IDX=$((SIDE_IDX + 1))
    sleep 0.2
  done

  # Phase 4: Switch desktops if more than one available
  DESK_COUNT=$(echo "$DESKTOPS" | wc -w)
  if [ "$DESK_COUNT" -gt 1 ]; then
    echo "  Switching desktops..."
    for DESK in $DESKTOPS; do
      send_quiet "{\"id\":1,\"cmd\":\"switch_desktop\",\"name\":\"$DESK\"}"
      sleep 0.5
    done
  fi

  # Check stats after this round
  CURRENT=$(python3 -c "
import socket, json
s = socket.socket(); s.settimeout(5); s.connect(('$HOST', $PORT))
s.sendall(b'{\"id\":1,\"cmd\":\"stats\"}\n')
buf = b''
while b'\n' not in buf: buf += s.recv(4096)
r = json.loads(buf.split(b'\n')[0])
print(r.get('result',{}).get('total_pushed', 0))
s.close()
")
  DELTA=$((CURRENT - BASELINE))
  echo "  Events so far: $CURRENT (+$DELTA from baseline)"
  echo ""
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Final stats
echo "=== Results ==="
FINAL=$(python3 -c "
import socket, json
s = socket.socket(); s.settimeout(5); s.connect(('$HOST', $PORT))
s.sendall(b'{\"id\":1,\"cmd\":\"stats\"}\n')
buf = b''
while b'\n' not in buf: buf += s.recv(4096)
r = json.loads(buf.split(b'\n')[0])
res = r.get('result',{})
print(f'{res.get(\"total_pushed\",0)} {res.get(\"buffer_used\",0)} {res.get(\"oldest_seq\",0)} {res.get(\"newest_seq\",0)}')
s.close()
")
TOTAL=$(echo "$FINAL" | cut -d' ' -f1)
USED=$(echo "$FINAL" | cut -d' ' -f2)
DELTA=$((TOTAL - BASELINE))

echo "Duration:       ${ELAPSED}s"
echo "Rounds:         $ROUNDS"
echo "Events total:   $TOTAL"
echo "Events this test: $DELTA"
echo "Buffer used:    $USED / 65536"
echo "Events/second:  $((DELTA / (ELAPSED > 0 ? ELAPSED : 1)))"

if [ "$DELTA" -gt 100000 ]; then
  echo ""
  echo "WARNING: >100K events in $ROUNDS rounds — autosizing storm detected"
fi

echo ""
echo "To inspect events: python3 tools/lcl-inspector.py events --max 50"
echo "To check for exceptions: python3 tools/lcl-inspector.py events --max 1000 | grep -i exception"

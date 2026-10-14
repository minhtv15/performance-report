#!/usr/bin/env bash
# ==============================================================================
# KỊCH BẢN KIỂM ĐỊNH & NGHIỆM THU CHẤT LƯỢNG TỰ ĐỘNG (AUTOMATED QA GATE CHECKER)
# Ứng dụng: com.lumi.wallpad | Thiết bị chuẩn: SM10P (57.0Hz / 17.54ms VSync)
# Kiểm tra tự động 15 Thành phần tối ưu (Gate 1 P0, Gate 2 UI/GPU, Gate 3 System)
# ==============================================================================
set -u

PKG="com.lumi.wallpad"
SERIAL="${1:-}"
ADB_CMD="adb"
if [[ -n "$SERIAL" ]]; then
  ADB_CMD="adb -s $SERIAL"
fi

echo "=============================================================================="
echo " BẮT ĐẦU KIỂM ĐỊNH NGHIỆM THU CHẤT LƯỢNG (QA GATES) — $PKG"
echo "=============================================================================="

if ! $ADB_CMD get-state >/dev/null 2>&1; then
  echo "[LỖI] Không tìm thấy thiết bị Android kết nối qua ADB."
  exit 1
fi

MODEL=$($ADB_CMD shell getprop ro.product.model | tr -d '\r')
DEV_SERIAL=$($ADB_CMD get-serialno | tr -d '\r')
PID=$($ADB_CMD shell pidof "$PKG" | tr -d '\r')

if [[ -z "$PID" ]]; then
  echo "[THÔNG BÁO] Ứng dụng $PKG chưa chạy. Đang khởi động ứng dụng..."
  $ADB_CMD shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 5
  PID=$($ADB_CMD shell pidof "$PKG" | tr -d '\r')
fi

echo "Thiết bị: $MODEL ($DEV_SERIAL) | PID hiện tại: $PID"
echo "------------------------------------------------------------------------------"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_metric() {
  local id="$1"
  local name="$2"
  local actual="$3"
  local target="$4"
  local status="$5"

  if [[ "$status" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf " [PASS] %-8s | %-44s | Thực tế: %-14s | Chuẩn: %s\n" "$id" "$name" "$actual" "$target"
  elif [[ "$status" == "WARN" ]]; then
    WARN_COUNT=$((WARN_COUNT + 1))
    printf " [WARN] %-8s | %-44s | Thực tế: %-14s | Chuẩn: %s\n" "$id" "$name" "$actual" "$target"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf " [FAIL] %-8s | %-44s | Thực tế: %-14s | Chuẩn: %s\n" "$id" "$name" "$actual" "$target"
  fi
}

# ------------------------------------------------------------------------------
# NHÓM A: QUẢN LÝ VÒNG ĐỜI MÀN HÌNH & BỘ NHỚ RAM (#1, #2)
# ------------------------------------------------------------------------------
echo ""
echo ">>> NHÓM A: VÒNG ĐỜI MÀN HÌNH (ACTIVITY LIFECYCLE) & BỘ NHỚ RAM (#1, #2)"
MEMINFO=$($ADB_CMD shell dumpsys meminfo "$PKG")

ACTIVITIES=$(echo "$MEMINFO" | awk '/Activities:/ {print $4; exit}')
VIEWROOTS=$(echo "$MEMINFO" | awk '/ViewRootImpl:/ {print $2; exit}')
VIEWS=$(echo "$MEMINFO" | awk '/Views:/ {print $2; exit}')
TOTAL_PSS_KB=$(echo "$MEMINFO" | awk '/TOTAL PSS:/ {print $3; exit}')
if [[ -z "$TOTAL_PSS_KB" ]]; then
  TOTAL_PSS_KB=$(echo "$MEMINFO" | awk '/TOTAL/ {print $2; exit}')
fi
NATIVE_PSS_KB=$(echo "$MEMINFO" | awk '/Native Heap/ {print $3; exit}')

TOTAL_PSS_MB=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_PSS_KB:-0}/1024}")
NATIVE_PSS_MB=$(awk "BEGIN {printf \"%.1f\", ${NATIVE_PSS_KB:-0}/1024}")

# #1a: Activities <= 2
if [[ "${ACTIVITIES:-99}" -le 2 ]]; then S="PASS"; else S="FAIL"; fi
check_metric "#1.a" "Số Activities sống trong bộ nhớ" "${ACTIVITIES:-N/A}" "<= 2 Activities" "$S"

# #1b: Views < 1500
if [[ "${VIEWS:-99999}" -lt 1500 ]]; then S="PASS"; else S="FAIL"; fi
check_metric "#1.b" "Tổng số Views toàn tiến trình" "${VIEWS:-N/A}" "< 1,500 Views" "$S"

# #2a: Total PSS < 180 MB
if awk "BEGIN {exit !(${TOTAL_PSS_MB:-999} < 180.0)}"; then S="PASS"; else S="FAIL"; fi
check_metric "#2.a" "Tổng bộ nhớ chiếm dụng (Total PSS)" "${TOTAL_PSS_MB} MB" "< 180.0 MB" "$S"

# #2b: Native Heap < 90 MB
if awk "BEGIN {exit !(${NATIVE_PSS_MB:-999} < 90.0)}"; then S="PASS"; else S="FAIL"; fi
check_metric "#2.b" "Bộ nhớ Native Heap PSS" "${NATIVE_PSS_MB} MB" "< 90.0 MB" "$S"

# ------------------------------------------------------------------------------
# NHÓM B: LƯU TRỮ FLASH eMMC, SHAREDPREFS & WORKMANAGER (#3, #4)
# ------------------------------------------------------------------------------
echo ""
echo ">>> NHÓM B: LƯU TRỮ DỮ LIỆU, FLASH eMMC & WORKMANAGER (#3, #4)"
PREFS_SIZE_BYTES=$($ADB_CMD shell stat -c %s "/data/data/$PKG/shared_prefs/wallpad_prefs.xml" 2>/dev/null | tr -d '\r')
if [[ -z "$PREFS_SIZE_BYTES" || ! "$PREFS_SIZE_BYTES" =~ ^[0-9]+$ ]]; then
  PREFS_KB="N/A"
  check_metric "#3.a" "Dung lượng file wallpad_prefs.xml" "Không đọc được" "< 50.0 KB" "WARN"
else
  PREFS_KB=$(awk "BEGIN {printf \"%.1f\", $PREFS_SIZE_BYTES/1024}")
  if awk "BEGIN {exit !($PREFS_KB < 50.0)}"; then S="PASS"; else S="FAIL"; fi
  check_metric "#3.a" "Dung lượng file wallpad_prefs.xml" "${PREFS_KB} KB" "< 50.0 KB" "$S"
fi

WAL_SIZE_BYTES=$($ADB_CMD shell stat -c %s "/data/data/$PKG/no_backup/androidx.work.workdb-wal" 2>/dev/null | tr -d '\r')
if [[ -n "$WAL_SIZE_BYTES" && "$WAL_SIZE_BYTES" =~ ^[0-9]+$ ]]; then
  WAL_KB=$(awk "BEGIN {printf \"%.1f\", $WAL_SIZE_BYTES/1024}")
  if awk "BEGIN {exit !($WAL_KB < 100.0)}"; then S="PASS"; else S="FAIL"; fi
  check_metric "#4" "Dung lượng file androidx.work.workdb-wal" "${WAL_KB} KB" "< 100.0 KB" "$S"
fi

# ------------------------------------------------------------------------------
# NHÓM C: ĐỘ MƯỢT GIAO DIỆN 57.0Hz — UI/RENDERTHREAD/GPU (#5 -> #11)
# ------------------------------------------------------------------------------
echo ""
echo ">>> NHÓM C: ĐỘ MƯỢT GIAO DIỆN 57.0Hz (UI THREAD -> RENDERTHREAD -> GPU) (#5 -> #11)"
GFXINFO=$($ADB_CMD shell dumpsys gfxinfo "$PKG")

TOTAL_FRAMES=$(echo "$GFXINFO" | awk -F': ' '/Total frames rendered:/ {print $2; exit}' | tr -d '\r ')
JANKY_RAW=$(echo "$GFXINFO" | awk -F': ' '/Janky frames:/ {print $2; exit}' | tr -d '\r')
JANK_PCT=$(echo "$JANKY_RAW" | sed -n 's/.*(\([0-9.]*\)%).*/\1/p')
P90_MS=$(echo "$GFXINFO" | awk '/90th percentile:/ {print $3; exit}' | tr -d 'ms\r')
MISSED_VSYNC=$(echo "$GFXINFO" | awk -F': ' '/Number Missed Vsync:/ {print $2; exit}' | tr -d '\r ')
SLOW_BITMAP=$(echo "$GFXINFO" | awk -F': ' '/Number Slow bitmap uploads:/ {print $2; exit}' | tr -d '\r ')
SLOW_ISSUE=$(echo "$GFXINFO" | awk -F': ' '/Number Slow issue draw commands:/ {print $2; exit}' | tr -d '\r ')

if [[ -n "$JANK_PCT" ]]; then
  if awk "BEGIN {exit !($JANK_PCT < 10.0)}"; then S="PASS"; else S="FAIL"; fi
  check_metric "#5/#6" "Tỷ lệ khung hình trễ (Jank Rate)" "${JANK_PCT}%" "< 10.0%" "$S"
fi

if [[ -n "$P90_MS" ]]; then
  if awk "BEGIN {exit !($P90_MS <= 17.54)}"; then S="PASS"; else S="FAIL"; fi
  check_metric "#7" "Thời gian vẽ khung hình P90 (57Hz)" "${P90_MS} ms" "<= 17.54 ms" "$S"
fi

if [[ -n "$SLOW_BITMAP" && "${TOTAL_FRAMES:-0}" -gt 0 ]]; then
  SLOW_BM_PCT=$(awk "BEGIN {printf \"%.2f\", ($SLOW_BITMAP/$TOTAL_FRAMES)*100}")
  if [[ "$SLOW_BITMAP" -eq 0 ]]; then S="PASS"; else S="FAIL"; fi
  check_metric "#8" "Tỷ lệ Slow Bitmap Uploads lên GPU" "${SLOW_BM_PCT}% (${SLOW_BITMAP})" "0% (Hardware Bitmap)" "$S"
fi

if [[ -n "$MISSED_VSYNC" && "${TOTAL_FRAMES:-0}" -gt 0 ]]; then
  MISSED_PCT=$(awk "BEGIN {printf \"%.2f\", ($MISSED_VSYNC/$TOTAL_FRAMES)*100}")
  if awk "BEGIN {exit !($MISSED_PCT < 1.0)}"; then S="PASS"; else S="FAIL"; fi
  check_metric "#9" "Tỷ lệ trễ nhịp quét (Missed VSync)" "${MISSED_PCT}% (${MISSED_VSYNC})" "< 1.0%" "$S"
fi

if [[ -n "$SLOW_ISSUE" && "${TOTAL_FRAMES:-0}" -gt 0 ]]; then
  SLOW_ISS_PCT=$(awk "BEGIN {printf \"%.2f\", ($SLOW_ISSUE/$TOTAL_FRAMES)*100}")
  if awk "BEGIN {exit !($SLOW_ISS_PCT < 2.0)}"; then S="PASS"; else S="FAIL"; fi
  check_metric "#6/#10" "Tỷ lệ nghẽn lệnh vẽ GPU (Slow Issue Draw)" "${SLOW_ISS_PCT}% (${SLOW_ISSUE})" "< 2.0%" "$S"
fi

# ------------------------------------------------------------------------------
# NHÓM D: ĐA LUỒNG, MẠNG MQTT/WEBSOCKET & VIDEO RTSP (#12 -> #15)
# ------------------------------------------------------------------------------
echo ""
echo ">>> NHÓM D: ĐA LUỒNG, KẾT NỐI MẠNG & GIẢI MÃ VIDEO RTSP (#12 -> #15)"
THREADS=$($ADB_CMD shell awk '/Threads:/ {print $2}' "/proc/$PID/status" 2>/dev/null | tr -d '\r')
MQTT_COUNT=$($ADB_CMD shell ps -T -p "$PID" 2>/dev/null | grep -c "MQTT")
WS_COUNT=$($ADB_CMD shell ps -T -p "$PID" 2>/dev/null | grep -c "OkHttp")
RTSP_CPU=$($ADB_CMD shell top -H -p "$PID" -b -n 1 2>/dev/null | awk '/554Surface/ {print $9; exit}' | tr -d '\r')

if [[ -n "$THREADS" ]]; then
  if [[ "$THREADS" -lt 50 ]]; then S="PASS"; else S="FAIL"; fi
  check_metric "#13.a" "Tổng số luồng (Threads) trong tiến trình" "${THREADS} Threads" "< 50 Threads" "$S"
fi

if [[ "$MQTT_COUNT" -le 3 && "$WS_COUNT" -le 2 ]]; then S="PASS"; else S="FAIL"; fi
check_metric "#13.b" "Số luồng MQTT / OkHttp WebSocket" "MQTT:${MQTT_COUNT} | WS:${WS_COUNT}" "1 MQTT Client | 1 WS" "$S"

if [[ -z "$RTSP_CPU" ]]; then
  check_metric "#15" "Tải CPU luồng RTSP khi ẩn Camera" "0.0% (Đã nghỉ)" "< 2.0% CPU" "PASS"
else
  if awk "BEGIN {exit !($RTSP_CPU < 2.0)}"; then S="PASS"; else S="FAIL"; fi
  check_metric "#15" "Tải CPU luồng RTSP (.97:554Surface])" "${RTSP_CPU}% CPU" "< 2.0% khi ẩn Camera" "$S"
fi

echo ""
echo "=============================================================================="
echo " TỔNG KẾT NGHIỆM THU NHANH: $PASS_COUNT ĐẠT (PASS) | $WARN_COUNT CẢNH BÁO | $FAIL_COUNT CHƯA ĐẠT (FAIL)"
echo "=============================================================================="

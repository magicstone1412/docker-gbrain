---
spec_version: 0.2.1
date: 2026-11-23
status: draft-untested        # chưa chạy thử với Docker/s6-overlay
baseline:
  entrypoint_sh: 834 dòng, section 0 đến 11
  dockerfile: base oven/bun, có util-linux, GBRAIN_HOME, ssh_config.d/50-gbrain.conf
  compose: PUID/PGID mặc định 1000, mount ./.config tại /home/gbrain/.gbrain và /root/.gbrain
changes:
  - version: 0.2.1
    items:
      - bất biến 3 sửa lại: file ssh được Include phải thuộc root (ssh từ chối owner khác root/người gọi); 00-identity ghi /etc/ssh/ssh_config.d/50-gbrain.conf bằng root
  - version: 0.2.0
    items:
      - bất biến 10 (lock ghi nhận ở /root/.gbrain: chmod o+x /root, giữ mount /root/.gbrain)
      - bất biến 11 (docker exec không đi qua s6)
      - 00-identity thêm bước chmod o+x /root
      - nghiệm thu mục 9 (lock đã ghi nhận); compose giữ hai mount cùng ./.config
  - version: 0.1.0
    items:
      - bản phác đầu: ánh xạ section sang cont-init.d/services.d, prompt cho agent
---

# Chuyển entrypoint.sh của gbrain sang s6-overlay (services.d)

> Trạng thái: **bản phác, chưa chạy thử.** Người viết không có Docker/s6-overlay trong môi trường soạn thảo.
> Mọi chỗ ghi "VERIFY" là giả định về hành vi của s6-overlay v3 mà agent thực thi phải tự kiểm chứng bằng test thật.

## 1. Mục tiêu và phạm vi

- Thay bản `entrypoint.sh` (khoảng 830 dòng, chạy nhiều vòng lặp nền bằng `&`) bằng s6-overlay: init một lần (`cont-init.d`) + dịch vụ được giám sát (`services.d`).
- **Giữ nguyên hành vi** (xem mục 6). Đây là refactor về quản lý tiến trình, không thêm tính năng.
- Giữ nguyên hai cách chạy đã có: root (mặc định) và non-root qua `PUID`/`PGID`.
- Ngoài phạm vi: đổi logic gbrain, đổi cấu hình DB (ví dụ `git_durability`), đổi secret trong compose.

## 2. Ánh xạ section của entrypoint.sh sang s6

| Section hiện tại | Chuyển thành | Loại |
|---|---|---|
| Đầu file: validate `GBRAIN_MODE`, `BRAIN_DIR`, `GBRAIN_SOURCE_ID`, `REFRESH_UPSTREAM` | `/etc/gbrain/lib.sh` (dùng chung) + chạy ở `00-identity` | init |
| 0. Identity / PUID / PGID / chown / `HOME=GBRAIN_HOME` | `cont-init.d/00-identity` | init, root |
| 1. Chờ Postgres | `cont-init.d/10-wait-postgres` | init |
| 2, 2b. Báo API key, chuẩn hóa endpoint | `cont-init.d/10-wait-postgres` (hoặc `15-env-report`) | init |
| 3, 4, 4b. Phát hiện/khởi tạo brain, cấu hình lại mỗi lần start | `cont-init.d/20-brain-init` | init, **chạy bằng user đích** |
| 5. Git repo + git config + `safe.directory` | `cont-init.d/30-git-repo` | init, user đích |
| 5b. SSH (copy key, `ssh_config`, `known_hosts`) | `cont-init.d/35-ssh` | init, user đích |
| 6. Source path trong Postgres | `cont-init.d/40-source` | init, user đích |
| 7. Auto-commit watcher (chỉ `classic`) | `services.d/autocommit` | longrun, chỉ khi classic |
| 8. Vòng lặp sync + embed (+ refresh upstream) | `services.d/sync-loop` | longrun |
| 9. Cài đặt autopilot (`--install`, parse `Start script:`, bỏ script `/root` cũ, sync env) | `cont-init.d/50-autopilot-install` | init, user đích |
| 9. Khởi động daemon autopilot (script tự `nohup` nền) | giữ ở `50-autopilot-install` (xem mục 5, điểm mở 1) | init |
| 10. Worker độc lập khi autopilot không sở hữu worker | `services.d/job-worker` | longrun, có điều kiện |
| 10b. Báo `git_durability` (chỉ đọc) | `cont-init.d/60-writer-report` | init |
| 11. `exec gbrain serve` (PID 1 cũ) | `services.d/serve` | longrun, **chủ chốt** |

## 3. Cấu trúc thư mục

```
rootfs/
  etc/
    gbrain/
      lib.sh                      # hàm dùng chung: is_uint, require_writable, fix_owner,
                                  #   as_user, refresh_upstream  (COPY NGUYÊN VĂN từ entrypoint.sh)
    cont-init.d/
      00-identity
      10-wait-postgres
      20-brain-init
      30-git-repo
      35-ssh
      40-source
      50-autopilot-install
      60-writer-report
    services.d/
      serve/        run  finish
      sync-loop/    run  finish
      autocommit/   run  finish      # chỉ classic
      job-worker/   run  finish      # chỉ khi autopilot không sở hữu worker
    ssh/ssh_config.d/50-gbrain.conf  # đã có trong Dockerfile hiện tại; giữ nguyên
```

Quy ước chung: mọi script bắt đầu bằng `#!/command/with-contenv sh` (VERIFY: đường dẫn `/command/` đúng với phiên bản v3 đã chọn) và `set -eu`.

## 4. Phác các script chính

### 4.1 Truyền biến giữa các bước

Shell của từng script cont-init không dùng chung biến. Cách truyền:

- Giá trị tính ra ở init (`BRAIN_DIR`, `GBRAIN_MODE`, `GBRAIN_SOURCE_ID`, `PUID`, `PGID`, `HOME`, `GIT_SSH_COMMAND`, `REFRESH_ENABLED`, `EMBED_CAP_ARGS`, `SYNC_INTERVAL`) được ghi thành từng file trong `/run/s6/container_environment/<TÊN>`; các script dùng `with-contenv` sẽ đọc được. (VERIFY)
- Cờ nội bộ không cần là biến môi trường (ví dụ "autopilot sở hữu worker") ghi vào `/run/gbrain/<tên>`.
- Hàm tiện ích để ghi: `export_env NAME VALUE` trong `lib.sh`.

### 4.2 Chạy lệnh dưới uid đích

`setpriv` và đoạn re-exec `/bin/sh "$0"` trong entrypoint **không còn cần**. Dùng:

```sh
# lib.sh
as_user() {   # chạy lệnh với uid:gid đích; không tra cứu /etc/passwd nên chạy được với uid tùy ý
  if [ "${PUID:-0}" = "0" ]; then "$@"
  else s6-applyuidgid -u "$PUID" -g "$PGID" -G "" "$@"; fi
}
```
Các bước 20 đến 60 gọi `as_user gbrain ...`, `as_user git ...`. Không được để `gbrain`/`git` chạy bằng root khi `PUID` khác 0, nếu không file sinh ra thuộc root và gây lại lỗi `EACCES` ở worktree lock.

### 4.3 `cont-init.d/00-identity` (rút gọn)

```sh
#!/command/with-contenv sh
set -eu
. /etc/gbrain/lib.sh
# 1) validate GBRAIN_MODE / BRAIN_DIR / ... (copy từ phần đầu entrypoint.sh)
# 2) PUID/PGID mặc định 0; kiểm tra is_uint
# 3) HOME="$GBRAIN_HOME" nếu đặt; export_env HOME / PUID / PGID
# 4) mkdir -p TARGET_HOME, $GBRAIN_HOME/.gbrain, BRAIN_DIR
# 5) chmod o+x /root    (chỉ khi PUID != 0; để uid non-root đi qua tới mount /root/.gbrain; xem mục 6, bất biến 10)
# 6) rm -rf "${SSH_RUNTIME_DIR:-/home/gbrain/.ssh-runtime}"      # tránh thư mục cũ thuộc uid khác
#    write_system_ssh_config (copy NGUYÊN VĂN từ entrypoint.sh): ghi /etc/ssh/ssh_config.d/50-gbrain.conf do root sở hữu, 0644,
#    liệt kê IdentityFile trỏ vào .ssh-runtime (xem bất biến 3)
# 7) khi PUID != 0: fix_owner (find-based, recursive) cho .gbrain và BRAIN_DIR; shallow cho HOME và cha của BRAIN_DIR
#    Lưu ý: /home/gbrain/.gbrain và /root/.gbrain là CÙNG thư mục host, nên chown một lần là đủ cho cả hai
# 8) require_writable cho .gbrain (exit 77 nếu không ghi được)
```

### 4.4 `services.d/serve/run` và `finish`

```sh
#!/command/with-contenv sh
. /etc/gbrain/lib.sh
SERVE_ARGS="--http --port 7333 --bind 0.0.0.0"
[ -n "${GBRAIN_PUBLIC_URL:-}" ] && SERVE_ARGS="$SERVE_ARGS --public-url $GBRAIN_PUBLIC_URL"
# shellcheck disable=SC2086
exec s6-applyuidgid -u "${PUID:-0}" -g "${PGID:-0}" -G "" gbrain serve $SERVE_ARGS
# (nếu PUID=0 thì bỏ s6-applyuidgid; viết thành hàm trong lib.sh)
```
```sh
#!/command/with-contenv sh
# finish: serve chết thì cả container phải thoát (giống PID 1 cũ), để restart policy của compose xử lý
echo "$1" > /run/s6-linux-init-container-results/exitcode   # VERIFY đường dẫn
exec /run/s6/basedir/bin/halt
```

### 4.5 `services.d/sync-loop/run`

Mỗi lần chạy = **một chu kỳ**, rồi `sleep` và thoát; s6 tự khởi động lại thành vòng lặp. Thân hàm lấy nguyên từ section 8 (refresh upstream, `sync`, `embed --stale`, các thông báo). Quy tắc bắt buộc: **một chu kỳ lỗi không được làm service dừng hẳn** (giống `|| echo ...` hiện tại). `finish` không `halt`.

### 4.6 `job-worker` và `autocommit` (chạy có điều kiện)

- `job-worker`: chạy `gbrain jobs work` chỉ khi `/run/gbrain/autopilot-owned` không phải `true`.
- `autocommit`: chạy chỉ khi `GBRAIN_MODE=classic`.
- Cơ chế tắt dịch vụ có điều kiện (VERIFY, chọn cách nào test chạy được):
  - A. `50-autopilot-install` / `00-identity` tạo file `/etc/services.d/<tên>/down` trước khi services được khởi động.
  - B. `run` thoát ngay, `finish` thoát với mã **125** (s6-supervise coi là lỗi vĩnh viễn, không restart).
  - C. `s6-svc -Od .` từ trong `run`.

## 5. Điểm mở cần agent quyết định bằng bằng chứng

1. **Autopilot daemon.** Script `start-autopilot-<hash>.sh` do `gbrain autopilot --install` sinh ra tự `nohup` nền, nên s6 **không** giám sát được. Bước đầu: giữ như hiện nay (khởi động ở `50-autopilot-install`, đặt cờ `autopilot-owned=true` chỉ khi script thoát 0). Giai đoạn sau (tùy chọn): đọc nội dung script sinh ra và `gbrain autopilot --help`; nếu có chế độ foreground, chuyển thành longrun `services.d/autopilot`. Nếu không chắc, giữ phương án bước đầu và ghi rõ trong báo cáo.
2. **Non-root khởi động trực tiếp** (`user: "1000:1000"` trong compose): s6-overlay v3 chạy được ở một số điều kiện nhưng cần `/run` ghi được. Không bắt buộc hỗ trợ trong lần này; **đường non-root được hỗ trợ là `PUID`/`PGID`**. Nếu thử thì ghi kết quả.
3. **Thời gian tắt.** `stop_grace_period: 60s` của compose phải lớn hơn tổng `S6_KILL_GRACETIME` (ms) + thời gian `serve` cần để drain. Đề xuất ban đầu: `S6_KILL_GRACETIME=45000`.

## 6. Bất biến (invariants) phải giữ, rút ra từ các lỗi đã gặp

1. `HOME` luôn bằng `GBRAIN_HOME` khi `GBRAIN_HOME` được đặt, ở mọi chế độ.
2. `fix_owner recursive` dùng `find ! -uid ... -o ! -gid ... -exec chown -h`, **không** chỉ kiểm tra thư mục gốc (file lock thuộc root nằm sâu trong `.gbrain/persistence/locks` gây `EACCES`).
3. SSH: key được copy vào `/home/gbrain/.ssh-runtime` (0700, key 0600). Cấu hình ssh dùng chung nằm ở `/etc/ssh/ssh_config.d/50-gbrain.conf`, **do root sở hữu, mode 0644**, được ghi ở pha root (`write_system_ssh_config`). **Không** để ssh đọc một file `ssh_config` thuộc uid thường qua `Include`: OpenSSH từ chối file Include có owner khác root và khác người gọi (`Bad owner or permissions`), nên shell `docker exec` (root) sẽ lỗi. Không dựa vào biến `GIT_SSH_COMMAND` đơn lẻ.
4. Autopilot: lấy đường dẫn script từ dòng `Start script:` của `--install`; không bao giờ chạy script có chứa `/root/.gbrain` khi config không ở `/root/.gbrain` (đổi tên thành `.stale-root`); script autopilot lỗi **không** được làm sập container, mà fallback sang `job-worker`.
5. `require_writable` thoát mã 77 kèm hướng dẫn sửa quyền.
6. `git config --global safe.directory "$BRAIN_DIR"` được thêm một lần (không nhân đôi).
7. Vòng sync không bao giờ chết vì một chu kỳ lỗi; `embed` chỉ chạy khi có `VOYAGE_API_KEY` hoặc `OPENAI_API_KEY`; `EMBED_MAX_USD_PER_RUN` thành `--max-usd`.
8. Script không được tự thay đổi cấu hình quản trị trong DB (ví dụ `git_durability`); chỉ cảnh báo.
9. Mọi lệnh `gbrain`/`git` ở bước init và service chạy bằng uid đích, không bằng root, khi `PUID` khác 0.
10. **Đường dẫn lock đã ghi nhận phải tiếp tục dùng được.** Lock của source `default` được ghi nhận ở `/root/.gbrain/persistence/locks/435c5cf2-7613-43e0-972e-3516ab9e7e91.lock` và gbrain không có lệnh nào di chuyển nó ("Do not delete ownership or lock files"). Vì vậy: (a) giữ mount `./.config:/root/.gbrain` trong compose; (b) `00-identity` chạy `chmod o+x /root` khi `PUID` khác 0; (c) không đổi `GBRAIN_HOME`, không xóa hay di chuyển file trong `persistence/locks`, không đặt `GBRAIN_COORDINATION_HOME` để "chuyển" lock (vô tác dụng với lock đã ghi nhận). Nếu agent thấy đường dẫn lock khác trên môi trường thật (`gbrain sources writer status --json`, trường `coordination_lock.path`), phải dùng đường dẫn đó thay cho giá trị trên.
11. Shell `docker exec` không có biến của s6 và chạy bằng root. Không đưa cấu hình cần cho `exec` vào `with-contenv` hay `container_environment`.

## 7. Thay đổi ở Dockerfile và compose

**Dockerfile**
- Cài `xz-utils`; tải và kiểm tra checksum hai tarball s6-overlay (`noarch` và theo kiến trúc, **ghim phiên bản v3.x cụ thể, chọn bản ổn định mới nhất tại thời điểm thực hiện**) rồi giải nén vào `/`.
- `COPY rootfs/ /`; `chmod +x` các script.
- `ENTRYPOINT ["/init"]`; bỏ `ENTRYPOINT` cũ và có thể bỏ `COPY entrypoint.sh` (giữ file dưới tên `/entrypoint.legacy.sh` để rollback).
- `ENV` gợi ý: `S6_BEHAVIOUR_IF_STAGE2_FAILS=2`, `S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0`, `S6_KILL_GRACETIME=45000`.
- Giữ nguyên: `util-linux`, `GBRAIN_HOME`, `/etc/ssh/ssh_config.d/50-gbrain.conf`, `chown 1000:1000` các thư mục, user `bun`/uid 1000.

**docker-compose.yml**
- **Bỏ `init: true`** (s6 phải là PID 1; nếu giữ, tini chiếm PID 1).
- Giữ `stop_grace_period: 60s`, mọi `environment` (gồm `PUID`/`PGID` mặc định 1000, `GBRAIN_HOME`, `GIT_CONFIG_*`), mọi mount.
- **Giữ nguyên hai mount trỏ cùng thư mục host:** `./.config:/home/gbrain/.gbrain` và `./.config:/root/.gbrain` (lý do: bất biến 10). Giữ `./state:/data`, `./brain:/data/brain`, `${HOME}/.ssh:/home/gbrain/.ssh:ro`.
- Rollback nhanh: thêm `entrypoint: ["/entrypoint.legacy.sh"]` và `init: true` trở lại; các mount không đổi.

## 8. Tiêu chí nghiệm thu

Người thực hiện chạy được Docker thì thực hiện tất cả; nếu không, ghi rõ mục nào **chưa test**.

1. `docker build` thành công; `shellcheck -s sh` sạch (hoặc ghi lại cảnh báo còn lại) cho mọi script.
2. **Root (PUID không đặt):** `docker compose up -d`; `docker exec gbrain id` là root; `GET /health` trên cổng 7333 trả OK; sync-loop in được ít nhất một chu kỳ trong log.
3. **Non-root (`PUID=1000 PGID=1000`):** `docker top gbrain` cho thấy `serve`, `sync`, worker chạy uid 1000; `./.config/persistence/locks/*` thuộc 1000; không có `EACCES`. Test lại với file lock thuộc root được tạo sẵn: sau khi start phải được sửa owner.
4. **SSH:** `docker exec gbrain ssh -G github.com` hiện `identityfile` và `userknownhostsfile` trỏ vào `/home/gbrain/.ssh-runtime/`; `docker exec -u <PUID>:<PGID> gbrain gbrain sources refresh default` không hỏi fingerprint.
5. **Autopilot:** script `/root/.gbrain/...` cũ (đặt sẵn để test) bị bỏ qua; script lỗi (giả lập `exit 1`) không làm container thoát và `job-worker` được bật.
6. **Giám sát:** `docker exec gbrain pkill -f "gbrain sync"` rồi chờ: vòng sync tiếp tục ở chu kỳ sau. `docker exec gbrain pkill -f "gbrain serve"`: container thoát và `restart: unless-stopped` khởi động lại.
7. **Tắt nhẹ:** `docker compose stop` hoàn tất trong `stop_grace_period`, không bị SIGKILL.
8. **Rollback** theo mục 7 chạy được.
9. **Lock đã ghi nhận:** với `PUID=1000`, `docker exec -u 1000:1000 <ctr> gbrain sources writer status --json` cho `coordination_lock.path` dưới `/root/.gbrain/persistence/locks/` và **không có trường `error`**; `docker exec -u 1000:1000 <ctr> namei -l <path>` đi hết đường dẫn; log không có `writer_lock_unavailable`/`EACCES` sau 5 phút. Test thêm: đặt sẵn file lock thuộc root trong `./.config/persistence/locks/`, sau khi start phải thuộc 1000 và serve mở được. Test với `chmod 700 /root` thủ công rồi restart: `00-identity` phải chạy lại `chmod o+x /root`.
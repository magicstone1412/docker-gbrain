# Triển khai gbrain bằng Docker

## 1. Tổng quan

Repository này cung cấp Docker wrapper cho [gbrain](https://github.com/garrytan/gbrain). Image thực hiện các công việc chính:

- build gbrain từ mã nguồn upstream;
- kết nối và khởi tạo PostgreSQL có `pgvector`;
- lưu brain tại `/data/brain` dưới dạng Git repository;
- đồng bộ nội dung và tạo embedding theo chu kỳ;
- tùy chọn chạy autopilot và job worker;
- cung cấp HTTP MCP server tại cổng `7333`.

Mặc định entrypoint chạy ở chế độ `classic`. File `docker-compose.yml` được cấu hình cho chế độ `managed` và sử dụng image đã publish `skywirex/gbrain:latest`.

## 2. Yêu cầu

- Docker có BuildKit/Buildx.
- PostgreSQL có extension `pgvector`.
- Biến `DATABASE_URL` trỏ đến database có thể truy cập từ container.
- Host PostgreSQL phải phân giải được thành `gbrain-postgres`, vì readiness check của entrypoint dùng cố định hostname và port `gbrain-postgres:5432`.
- API key embedding là tùy chọn. Nếu không có key, gbrain vẫn chạy nhưng vector search và background embedding bị tắt.

## 3. Build image

Build từ tag upstream mặc định:

```sh
docker build -t docker-gbrain .
```

Build từ một tag cụ thể:

```sh
docker build \
  --build-arg GBRAIN_TAG=v0.60.483.0 \
  -t docker-gbrain .
```

CI sử dụng giá trị trong file `GBRAIN_VERSION` để build và publish image cho `linux/amd64` và `linux/arm64`.

## 4. Chạy bằng Docker

Tạo network và bảo đảm PostgreSQL có tên `gbrain-postgres`, sau đó chạy container:

```sh
docker run --rm \
  --name gbrain \
  --network gbrain-net \
  -e DATABASE_URL='postgresql://user:password@gbrain-postgres:5432/gbrain' \
  -e VOYAGE_API_KEY='pa-...' \
  -p 7333:7333 \
  -v gbrain-brain:/data/brain \
  docker-gbrain
```

Sau khi khởi động:

- giao diện/server có tại `http://localhost:7333`;
- MCP endpoint thường có tại `http://localhost:7333/mcp`.

Kiểm tra container:

```sh
docker exec -it gbrain /bin/bash
```

## 5. Chọn embedding provider

Entrypoint chọn provider theo thứ tự sau:

1. Có `VOYAGE_API_KEY`: dùng `voyage:voyage-4`, 1024 dimensions.
2. Không có Voyage nhưng có `OPENAI_API_KEY`: dùng `openai:text-embedding-3-large`, 3072 dimensions.
3. Không có key nào: chạy với `--no-embedding`.

Nếu đổi provider trên database đã tồn tại, cần tạo lại embedding cho nội dung cũ:

```sh
gbrain embed --stale
```

`gbrain init` ghi đè config, vì vậy entrypoint luôn áp dụng lại embedding configuration sau bước init.

## 6. Các biến runtime chính

| Biến | Mặc định | Chức năng |
| --- | --- | --- |
| `DATABASE_URL` | bắt buộc | Connection string đến PostgreSQL. |
| `VOYAGE_API_KEY` | — | API key cho Voyage embedding. |
| `OPENAI_API_KEY` | — | OpenAI embedding và chat provider. |
| `ANTHROPIC_API_KEY` | — | Chat provider tùy chọn cho autopilot. |
| `OPENAI_BASE_URL` | — | OpenAI-compatible endpoint; entrypoint thêm `/v1` nếu thiếu. |
| `ANTHROPIC_BASE_URL` | — | Anthropic-compatible endpoint; entrypoint thêm `/v1` nếu thiếu. |
| `GBRAIN_MODE` | `classic` | Chọn `classic` hoặc `managed`. |
| `BRAIN_DIR` | `/data/brain` | Đường dẫn brain bên trong container. |
| `GBRAIN_SOURCE_ID` | `default` | Source dùng cho managed sync. |
| `SYNC_INTERVAL` | `900` | Số giây giữa các chu kỳ sync/embed. |
| `EMBED_MAX_USD_PER_RUN` | `1` | Mức chi tối đa cho mỗi background embedding run; để trống để tắt giới hạn. |
| `AUTOPILOT_ENABLED` | `false` | Bật autopilot; cần embedding key. |
| `BRAIN_REMOTE` | — | Git SSH remote tùy chọn cho brain repository. |
| `GBRAIN_PUBLIC_URL` | — | URL thực tế mà client gọi; được truyền cho OAuth issuer. |
| `GBRAIN_HOME` | — | Thư mục gốc tùy chọn của gbrain state và config. |

## 7. Quyền ghi và tính nhất quán của Brain

Một Brain lưu cùng một nội dung ở hai nơi:

1. các file `.md` trong `/data/brain` — bản chuẩn (source of truth), được quản lý bằng Git;
2. database PostgreSQL — chỉ mục phục vụ tìm kiếm và các thao tác của gbrain.

Vấn đề quan trọng là xác định ai được phép ghi trang để hai nơi này không bị lệch nhau.

Lỗi `owner_unavailable` có nghĩa là source `default` chưa có chủ sở hữu hợp lệ. Khi Hermes gọi `put_page`, gbrain sẽ từ chối thao tác thay vì tự đoán process nào được phép ghi.

Có thể hình dung như một thư viện:

- Ở `classic`, mọi người có thể đặt sách lên kệ (ghi file), còn thủ thư kiểm kê định kỳ (sync).
- Ở `managed`, chỉ một thủ thư nhận sách qua quầy, ghi sổ, xếp sách lên kệ và báo lên kho trung tâm (Git). Nhờ vậy, kệ và sổ luôn khớp nhau.

### Claim và activate

Managed mode được thiết lập qua hai bước, theo đúng thứ tự và liền mạch.

#### Bước 1: Claim — bổ nhiệm chủ sở hữu

```sh
gbrain sources writer claim default --path /data/brain
```

Lệnh này ghi nhận rằng gbrain là chủ sở hữu của thư mục `/data/brain`. Nó tạo dấu niêm phong trong checkout và một bản đăng ký cạnh thư mục, giúp ngăn hai instance gbrain cùng nhận một thư mục.

Nếu hệ thống yêu cầu trạng thái quản trị kỳ vọng, thêm:

```sh
gbrain sources writer claim default \
  --path /data/brain \
  --expected-state <admin_state>
```

`--expected-state <admin_state>` là chốt an toàn: nếu một process khác vừa thay đổi cấu hình quản trị, giá trị cũ sẽ bị từ chối thay vì ghi đè thay đổi mới.

Sau khi claim, các đường ghi kiểu cũ — chẳng hạn classic sync hoặc ghi file thủ công trực tiếp vào checkout — sẽ bị chặn.

#### Bước 2: Activate — mở quầy ghi

```sh
gbrain sources writer activate default --confirm-quiesced
```

`activate` bật managed persistence. Từ thời điểm đó, mọi lần ghi phải đi qua một điểm điều phối duy nhất. Cờ `--confirm-quiesced` yêu cầu xác nhận rằng không còn process nào khác đang ghi vào brain.

Claim nhưng chưa activate là trạng thái lửng: các đường sync cũ đã bị chặn nhưng `put_page` chưa được phép chạy. Vì vậy, cần thực hiện claim và activate trong cùng một quy trình chuyển đổi, sau khi đã dừng/quiesce các writer khác.

## 8. Hai chế độ vận hành

#### Classic

Đây là chế độ mặc định của image:

- chạy watcher auto-commit mỗi 30 giây;
- dùng `gbrain sync --repo /data/brain`;
- phù hợp khi container là tiến trình sở hữu việc commit và đồng bộ brain.

#### Managed

Đây là chế độ mặc định của Compose:

- tắt auto-commit watcher;
- dùng `gbrain sync --source <GBRAIN_SOURCE_ID> --no-pull`;
- yêu cầu source đã được claim và activate trước đó;
- coi `gbrain serve` là owner chính của brain.

Trong managed mode, entrypoint chỉ đọc trạng thái `git_durability` và cảnh báo nếu trạng thái không phải `on`/`enabled`. Entrypoint không tự thay đổi quyền ownership hoặc durability. Nếu cần bật durability, operator phải thực hiện theo CLI của gbrain, sau khi kiểm tra dry-run.

Không chuyển một managed brain về `classic` nếu chưa deactivate writer trước. Ngược lại, không dùng managed mode cho source chưa được claim/activate.

## 9. Brain repository và SSH remote

Mount `/data/brain` để giữ nội dung qua các lần recreate container. Ở lần chạy đầu, entrypoint:

1. khởi tạo thư mục thành Git repository nếu cần;
2. trỏ source mặc định của database vào đường dẫn này;
3. cấu hình `origin` và branch tracking nếu có `BRAIN_REMOTE` và SSH keys.

Ví dụ dùng private SSH remote:

```sh
-e BRAIN_REMOTE='git@github.com:you/brain.git' \
-v "$HOME/.ssh:/root/.ssh:ro"
```

Vì `/root/.ssh` được mount read-only, known hosts được ghi vào `/tmp/known_hosts`. `GIT_SSH_COMMAND` phải dùng đường dẫn writable này. Nếu không mount SSH keys, repository vẫn hoạt động local-only.

## 10. Chạy bằng Docker Compose

Compose tạo một PostgreSQL `pgvector` riêng và chờ health check trước khi khởi động gbrain. Stack mặc định:

- dùng image `skywirex/gbrain:latest`, không build từ thư mục hiện tại;
- dùng database `gbrain`, user `gbrain`, password phát triển `gbrain123`;
- bật `GBRAIN_MODE=managed`;
- bật autopilot;
- đặt `SYNC_INTERVAL=600`;
- mount `./state` vào `/data`;
- mount `./brain` vào `/data/brain`;
- mount `./.config` vào `/root/.gbrain`;
- mount `${HOME}/.ssh` read-only vào `/root/.ssh`;
- publish cổng `7333` trên mọi interface của host.

Khởi động:

```sh
export VOYAGE_API_KEY=pa-...
docker compose up -d
```

Có thể đặt các biến tùy chọn trong file `.env`, chẳng hạn `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `SYNC_INTERVAL`, `EMBED_MAX_USD_PER_RUN`, `AUTOPILOT_ENABLED` và `BRAIN_REMOTE`.

### Lưu ý khi phát triển image

Compose dùng image đã publish. Vì vậy thay đổi local trong `Dockerfile` hoặc `entrypoint.sh` không tự động được sử dụng. Để kiểm thử thay đổi local, hãy build image rồi chạy trực tiếp, hoặc chủ động đổi service Compose sang `build: .`.

## 11. Trình tự khởi động

Entrypoint thực hiện các bước sau:

1. Chờ `gbrain-postgres:5432` sẵn sàng.
2. Kiểm tra sự hiện diện của API keys và chuẩn hóa custom base URLs.
3. Kiểm tra bảng `pages` để xác định database đã được khởi tạo.
4. Chạy `gbrain init` cho lần đầu hoặc chạy migrations cho database hiện có.
5. Áp dụng lại embedding configuration và giới hạn chi phí sau `init`.
6. Khởi tạo brain repository và cập nhật local path của source.
7. Chạy classic watcher hoặc managed sync tùy `GBRAIN_MODE`.
8. Định kỳ sync và embed nội dung stale nếu có embedding key.
9. Tùy chọn khởi động autopilot; nếu autopilot không sở hữu worker, khởi động `gbrain jobs work`.
10. Chạy foreground server:

```sh
gbrain serve --http --port 7333 --bind 0.0.0.0
```

Nếu đặt `GBRAIN_PUBLIC_URL`, entrypoint thêm `--public-url` để OAuth issuer khớp với URL mà client thực sự sử dụng.

## 12. Bảo mật và vận hành

- Đổi password PostgreSQL `gbrain123` trước khi dùng ngoài môi trường tin cậy.
- Cổng `7333` đang được publish trên `0.0.0.0`; hãy giới hạn bằng firewall, private network hoặc bind vào interface riêng.
- Không commit API keys, SSH keys, `.config`, `brain` hoặc runtime state.
- Dùng volume/bind mount persistent cho database, `/data` và `/data/brain`.
- Khi đổi provider embedding, kiểm tra dimension và chạy lại `gbrain embed --stale`.
- Trước khi dùng managed mode, xác nhận source đúng path, đã claim/activate và có chính sách writer phù hợp.

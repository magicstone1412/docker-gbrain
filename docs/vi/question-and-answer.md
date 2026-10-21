Câu hỏi: nếu tôi commit repo brain sang một máy khác và commit trên máy đó và push lên github thì vấn đề gì sẽ xảy ra?

Câu trả lời phụ thuộc vào cách gbrain xử lý commit từ xa khi nó là owner. Đọc mục "worktree refresh refusals" của upstream để trả lời chính xác thay vì suy đoán.

Có chuyện xảy ra, nhưng không có gì bị mất. Bản đọc gần nhất của tôi là `topologies.md` và `write-refusals.md` ở v0.60.310.0. Phần "worktree refresh refusals", chỗ mô tả `gbrain sources refresh` có thể từ chối khi nào, bị cắt khỏi trang tôi đọc nên tôi chưa đọc, và tôi ghi rõ chỗ đó bên dưới.

## Điều gì xảy ra khi máy kia push lên `master`

**1. Brain host không tự biết.** Brain managed không bao giờ chạy `git pull` trong chu kỳ tự động. Tài liệu ghi rằng một lệnh `gbrain sync` tường minh không có `--no-pull` bị từ chối với `writer_coordinator_required`, còn chu kỳ không giám sát thì sync checkout như hiện có và chỉ báo cáo. Entrypoint của bạn cũng dùng `--no-pull`. Doctor (`sync_freshness`) sẽ báo "upstream N commit(s) ahead" thay vì tự cập nhật.

**2. Cách đưa commit từ xa vào:** `gbrain sources refresh <source>`. Lệnh này chặn ghi vào checkout, fast-forward tới upstream, rồi chạy managed sync cho mọi source gắn với checkout đó. Chỉ fast-forward, nên chỉ chạy được khi lịch sử không phân kỳ (xem mục 3).

**3. Chỗ nguy hiểm là phân kỳ.** Owner commit và push HEAD sau mỗi lần ghi trang, nhưng nó không bao giờ pull hay rebase checkout; push bị remote từ chối thì được thử lại, và sau nhiều lần thất bại thì bị "park". Nếu máy kia push trước, rồi Hermes ghi một trang mới trên brain host trong lúc commit local chưa kịp push, hai bên có commit mà bên kia không có. Khi đó push của owner bị từ chối, sau 5 lần liên tiếp nó bị park (`parked_effects` của doctor): trang vẫn được ghi và commit local, nhưng bản sao lưu Git của nó chưa trọn vẹn. `refresh` bằng fast-forward cũng không thể gộp. Tôi chưa đọc cách upstream xử lý trường hợp này nên không đưa lệnh cứu; hãy đọc mục "worktree refresh refusals" trong `write-refusals.md` và backup `brain/` trước khi làm gì. Tuyệt đối không `git pull --rebase`, `git reset` hay `git checkout` trên đường dẫn trang trong checkout của brain host: upstream nói rõ owner không pull và việc di chuyển file dưới chân nó chính là điều `source_changed` bảo vệ.

**4. Xung đột nội dung.**
- Máy kia sửa một trang mà DB cũng đã đổi: owner dừng lại thay vì ghi đè (`file_database_drift`). Cả file lẫn bản trong DB đều không bị ghi đè.
- Commit từ xa chưa được sync nhập vào: trang đó ở trạng thái `pending_import`, và các ghi như `put_page` vào trang đó bị từ chối cho tới khi chạy `gbrain sync --source <source> --no-pull`. Hermes sẽ thấy lỗi khi ghi vào trang đang chờ.
- Atom suy ra từ trang gốc bị đánh dấu stale (`origin_changed`, như bạn đã thấy lúc trước).

**5. Push tay không qua bước quét bí mật** của owner (bước quét bí mật không chạy với push tay), nên hãy tự kiểm tra trước khi push từ máy kia.

## Khuyến nghị theo thứ tự

1. **Dùng máy kia làm client MCP** (`put_page`/`edit_page` qua Hermes hoặc công cụ khác), không làm peer Git. Đây là đường upstream thiết kế cho managed brain.
2. **Nếu chỉ cần đọc hay soạn bằng editor:** clone chỉ-đọc (chỉ `git pull`, không commit lên `master`).
3. **Nếu bắt buộc commit từ máy kia:**
   - Trên máy kia: `git pull --rebase` trước **mỗi** lần push; chỉ thêm file mới hoặc sửa file mà owner không đang ghi; commit nhỏ.
   - Trên brain host, ngay sau khi push xong: `gbrain sources refresh default`, rồi `gbrain sync --source default --no-pull`.
   - Kiểm tra: `gbrain doctor --only sync_freshness` và `gbrain doctor --only parked_effects`.
   - Không để owner ghi trong lúc bạn làm việc đó (tạm dừng Hermes). Cửa sổ phân kỳ nhỏ nhất khi không ai ghi.

## Một cải thiện cho entrypoint (chưa làm)

Entrypoint r3 dùng `--no-pull` nên commit từ xa không tự vào. Tôi có thể thêm vòng `gbrain sources refresh` định kỳ (có biến bật/tắt, mặc định tắt) để brain host tự đuổi theo `origin`. Tôi chưa xác minh cú pháp và các từ chối của `refresh`, nên nếu bạn muốn, tôi sẽ đọc mục "worktree refresh refusals" trước rồi mới viết, thay vì đoán.

Trước khi viết, tôi đọc mục "worktree refresh refusals" mà trang trước bị cắt mất, để vòng `refresh` dựa trên tài liệu chứ không phải suy đoán.

Tôi chạy thử vòng lặp thật (đoạn trích nguyên văn từ file) với `gbrain`, `git` và `sleep` giả lập, chạy đúng một vòng.

Tôi đã triển khai xong bản r4 trong `gbrain-wrapper-r4/`. Vòng refresh định kỳ mặc định tắt, nên chạy bình thường nếu bạn không bật. `sh -n` và `shellcheck` sạch, YAML hợp lệ. Tôi đã chạy đoạn vòng lặp thật trích nguyên văn từ file, với `gbrain`, `git` và `sleep` giả lập, nhưng chưa chạy `docker build` hay container thật.

## Những gì đã thêm

**Biến `GBRAIN_REFRESH_UPSTREAM`** (`true|false`, mặc định `false`; giá trị khác bị từ chối ngay đầu file với exit 2). Khi bật, trong mỗi chu kỳ sync (cứ `SYNC_INTERVAL`, mặc định 600 giây) entrypoint chạy `gbrain sources refresh default` **trước** `gbrain sync --source default --no-pull`. Đây đúng là thứ tự upstream khuyến nghị cho brain managed.

Hành vi tôi thử với từng kịch bản:
- Managed, bật, có `origin`: chạy refresh, rồi sync, rồi embed, đúng thứ tự.
- Refresh **lỗi hoặc bị từ chối**: ghi `[refresh] refused or failed (exit N)` kèm gợi ý `sources refresh default --dry-run`, rồi vẫn chạy sync. Việc này có chủ ý: sync cũng có thể gỡ trạng thái `sync_in_progress` khiến refresh từ chối.
- Mặc định (tắt): không đổi gì so với r3.
- Classic, hoặc managed nhưng repo không có remote `origin`: cảnh báo "bị bỏ qua" và không chạy refresh.

Compose r4 thêm `GBRAIN_REFRESH_UPSTREAM: ${GBRAIN_REFRESH_UPSTREAM:-false}` và đổi tag image thành `...-r4`.

## Trước khi bật

1. **Commit `RESOLVER.md` trước.** Sau khi bật git durability, file này bị sửa chưa commit. Refresh từ chối với `refresh_dirty` khi checkout có thay đổi chồng lên vùng commit sắp vào; tôi chỉ đọc được mã này qua issue (#6846), chưa đọc tài liệu đầy đủ về nó.
2. **Chạy thử bằng tay một lần** trong container: `gbrain sources refresh default --dry-run`. Lệnh này cho thấy nó sẽ làm gì và từ chối ở đâu mà không thay đổi gì.
3. **Hermes có thể bị từ chối ngắn** (`worktree_refreshing`) trong lúc refresh chặn ghi để fast-forward. Mã này nằm trong danh sách lỗi managed mà upstream liệt kê, nhưng tôi chưa biết thời gian chặn thường kéo dài bao lâu. Nếu Hermes không tự thử lại, cần dặn nó thử lại.
4. Bật bằng cách thêm `GBRAIN_REFRESH_UPSTREAM=true` vào `.env` rồi recreate. Log khởi động phải có `Upstream refresh before each sync cycle: true`.

## Cách kiểm tra khi chạy thật

Từ một clone khác, push một file mới lên `master`. Trong khoảng một chu kỳ (tối đa `SYNC_INTERVAL`), log phải có `[refresh] done`, file xuất hiện trong `~/docker/gbrain/brain`, và `gbrain get <slug>` trả về trang. Kiểm tra thêm `gbrain doctor --only sync_freshness` (không còn "upstream N commit(s) ahead") và `parked_effects`.

## Những điều tôi chưa xác minh

- Danh sách đầy đủ 12 mã từ chối của refresh và cách xử lý từng mã: mục "worktree refresh refusals" nằm ngoài tầm đọc của công cụ. Tôi chỉ biết `refresh_diverged`, `refresh_dirty`, `sync_in_progress`, `worktree_refreshing`, `writer_coordinator_required` qua PR và issue. Vì vậy vòng lặp chỉ ghi log lỗi chứ không tự sửa gì.
- Có issue (#6834) mô tả vòng bế tắc: refresh bị `sync_in_progress` còn sync không gỡ được cursor. Nếu bạn thấy `[refresh] refused` lặp lại nhiều chu kỳ, đó là chỗ cần xem, và log cũng ghi lệnh `--dry-run` để lấy nguyên nhân.
- Tên tag `v0.60.310.0-r4` có thể gây hiểu nhầm, vì container của bạn chạy 0.60.329.0. Hãy xem `docker compose exec gbrain cat /app/.gbrain-build-info` rồi build với `--build-arg GBRAIN_TAG=<đúng phiên bản đó>` và đặt tên tag khớp với nó.

Trình tự triển khai giống lần trước (build, push, `docker run ... od -c` kiểm tra shebang không có `\r`, rồi `docker compose up -d --force-recreate gbrain` khi Hermes đang tạm dừng ingest). Muốn tôi viết prompt cho agent thực hiện việc này (kiểm tra SQL `local_path`, build, recreate, đối chiếu log và `writer status`) thì nói tôi biết.
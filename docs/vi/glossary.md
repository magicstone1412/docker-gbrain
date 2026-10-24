## Glossary

| Thuật ngữ | Giải thích ngắn |
|---|---|
| **Durability** (Git durability) | Cài đặt cho biết owner có **commit và push** mỗi trang vừa ghi lên Git hay không. Tắt: trang chỉ có trong DB và file trên máy này. Bật: trang cũng có trên GitHub. |
| **`on` / `off` / `unknown`** | Ba giá trị hiển thị trong `writer status`. `unknown` là chưa từng thiết lập. |
| **`durability_not_enabled`** | Trạng thái của một lần ghi hoàn tất khi durability tắt: file đã ghi, chưa commit. Đây là lý do file bị untracked. |
| **`--enable`** | Lệnh bật. Thăm dò `git push --dry-run`, ghi nhận cài đặt, rồi đưa các lần ghi cũ vào hàng đợi commit bù. |
| **`push_probe`** | Bước thử push chỉ-đọc của `--enable`. `ok: true` nghĩa là SSH và quyền đã đủ. |
| **`catch_up`** | Danh sách các file chưa commit sẽ được commit và push bù ngay sau khi bật. |
| **Git effect** | Công việc commit/push mà owner xếp hàng sau mỗi lần ghi trang. |
| **Parked** (bị park) | Effect thất bại nhiều lần liên tiếp nên bị gác lại. Xem bằng `gbrain doctor --only parked_effects`. |
| **Canonical owner** | Tiến trình `gbrain serve` được chỉ định làm nơi duy nhất ghi trang vào source. |
| **Claim / Activate** | Claim: chỉ định owner cho source. Activate: bật managed persistence. Phải làm liền nhau. |
| **Managed / Classic** | Managed: owner ghi và commit. Classic: ghi file tự do, watcher của entrypoint tự commit. |
| **`admin_state`** | Dấu vân tay trạng thái quản trị; đổi sau mỗi thay đổi. Lệnh quản trị phải kèm `--expected-state` để chống ghi đè mù. |
| **`--admin-intent`** | Cờ ghi rõ hành động quản trị bạn định làm, để lệnh không chạy nhầm. |
| **`sources refresh`** | Lệnh kéo commit mới từ `origin` vào checkout (chỉ fast-forward), rồi sync. Owner không tự pull. |
| **`--no-pull`** | Cờ của `sync` cho managed brain: chỉ nhập commit đã có, không kéo từ remote. |
| **Atom** | Đơn vị tri thức nhỏ, tự chứa được trích xuất từ nội dung nguồn hoặc ghi thủ công; thường biểu đạt một ý, nhận định, trích dẫn hay mẩu thông tin có thể tái sử dụng độc lập. Trong schema pack, `atom` là một page type và có thể mang subtype như `extraction`, `manual` hoặc `lore`. |
| **DB-only** | Dữ liệu chỉ nằm trong DB, không có file. Durability không bảo vệ được; cần `pg_dump`. |
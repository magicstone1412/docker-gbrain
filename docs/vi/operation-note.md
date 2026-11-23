# Ghi chú vận hành: đồng bộ và phục hồi brain từ Git

Ghi chú này hướng dẫn vận hành `/data/brain` khi brain được lưu trong Git, có máy khác clone repository để chỉnh sửa và push lên remote (ví dụ GitHub), hoặc khi cần phục hồi sau sự cố chỉ còn repository trên GitHub.

> **Phạm vi:** Nội dung tập trung vào `GBRAIN_MODE=managed`, là chế độ Compose sử dụng. Các lệnh và hành vi có thể thay đổi theo phiên bản gbrain; khi xử lý sự cố, ưu tiên thông báo lỗi và tài liệu của đúng phiên bản đang chạy.

## Chuẩn bị brain repository

Bắt đầu từ schema brain được khuyến nghị của upstream: [GBRAIN_RECOMMENDED_SCHEMA.md](https://github.com/garrytan/gbrain/blob/master/docs/GBRAIN_RECOMMENDED_SCHEMA.md). Tài liệu mô tả các file và quy ước trang mà một brain repository nên tuân theo; hãy dùng nó làm khuôn khi khởi tạo `/data/brain` lần đầu.

## Nguyên tắc vận hành

- Một commit được push từ máy khác **không tự động xuất hiện** trong checkout của brain host ở managed mode.
- Cách upstream hỗ trợ để đưa commit từ remote vào managed checkout là:

  ```sh
  gbrain sources refresh default
  ```

  Sau đó chạy sync không pull:

  ```sh
  gbrain sync --source default --no-pull
  ```

- Trong wrapper này, có thể bật tự động refresh trước mỗi chu kỳ sync bằng:

  ```env
  GBRAIN_REFRESH_UPSTREAM=true
  ```

- **Không dùng `git pull`, `git pull --rebase`, `git reset` hoặc sửa trực tiếp các file page trong managed checkout.** Managed worktree có owner/coordinator riêng; ghi Git trực tiếp có thể bị từ chối hoặc làm database và checkout lệch nhau.
- Cách an toàn nhất để thay đổi nội dung từ máy khác là dùng máy đó làm **MCP client** và ghi qua gbrain, thay vì coi brain host và máy kia là hai Git writer ngang hàng.

## Xử lý file bị lệch khỏi database (drift)

### Nhận biết drift

Ở chế độ `GBRAIN_MODE: managed`, mọi lần ghi vào page đều đi qua gbrain để database và file luôn khớp nhau. Khi bạn sửa thẳng file trong `/data/brain`, file khác database. gbrain gọi tình trạng này là **drift**. Page bị drift sẽ từ chối mọi lần ghi có điều phối (`source_changed`) và maintenance bỏ qua page đó, cho tới khi bạn chọn bản nào là đúng.

### Kiểm tra drift

Chạy `gbrain doctor`. Nếu có dòng này là có drift:

```text
[WARN] maintenance_write_drift: 1 page(s) have a canonical file that differs from the database ...
```

### Xác định page bị lệch

```bash
gbrain sources reconcile default --brain host --audit --conflicts
```

Chỉ quan tâm slug có `still_present.reason: "file_database_drift"` (với resolver là slug `resolver`, file `RESOLVER.md`). Các slug có `agrees` là xung đột cũ đã khớp lại, còn `page_missing` là page đã bị xóa. Hai loại này không cần xử lý.

### Nhập file vào database

Dùng `--prefer file`. Làm theo thứ tự:

```bash
# 1. Sao lưu file (rất nhanh, nên làm)
cp /data/brain/RESOLVER.md /tmp/RESOLVER.bak.md

# 2. Preview, chưa ghi gì
gbrain repair file-drift --source default --all-drifted --prefer file

# 3. Apply, dùng đúng hash mà bước 2 in ra
gbrain repair file-drift --source default --all-drifted --prefer file --apply --expect <hash>

# 4. Kiểm tra lại
gbrain doctor
```

**Nhiều page bị drift thì làm từng page, bắt đầu bằng preview.** Ví dụ muốn sửa drift của 2 file RESOLVER.md và log.md thì thực hiện như sau:

**`resolver`:**

```bash
gbrain repair file-drift --source default --slug resolver --prefer file
```

**`log`:**

```bash
gbrain repair file-drift --source default --slug log --prefer file
```

Mỗi lệnh chỉ in preview và một hash riêng. Đọc kỹ danh sách và phần `exceptions`, rồi áp dụng bằng đúng hash do **lệnh preview đó** in ra:

```bash
gbrain repair file-drift --source default --slug resolver --prefer file --apply --expect <hash của resolver>
```

Hash của hai page khác nhau, nên làm xong page này rồi mới chạy preview page kia.

### Kiểm tra preview trước khi áp dụng

- `file-drift: 1 item(s) to repair` và `e.g. default:resolver`: danh sách chỉ có page bạn sửa. Vì `--all-drifted` áp dụng cho mọi page lệch, nếu thấy page lạ thì dừng lại.
- `prefer_file: ... (exactly the preferred side)` và `import the file into the page`: gbrain sẽ nhập nội dung file vào database.
- Dòng `unknown: ... page_missing` là các page đã bị xóa. Lệnh không đụng tới chúng, bỏ qua được.
- Dòng `cost`: thường 1 page cần embed lại, chi phí gần như bằng 0.

### Phạm vi thay đổi khi ưu tiên file

Theo thông báo của preview: metadata được bảo vệ vẫn giữ theo database, tags là hợp của cả hai bên, còn takes được bảo vệ và private fact rows được giữ. File của bạn không bị thay đổi, vì lệnh chỉ import file vào database.

### Ghi database đè lên file

Dùng `--prefer database` thay cho `--prefer file`, cùng quy trình preview rồi apply. Cẩn thận vì file sẽ bị ghi đè, hãy sao lưu trước.

### Xử lý `STOPPED: writer_lock_unavailable`

Không hỏng. Đó là hành vi đã thấy với `repair stale-atoms`: lệnh chạy một lần từ CLI mất quyền ghi giữa chừng, nhưng tiến độ được lưu. Chạy lại đúng lệnh là nó tiếp tục. Với file-drift chỉ 1 page nên thường xong ngay. Lúc đó đừng xóa file `.lock` và đừng tự kill tiến trình `serve`.

### Khôi phục autopilot

Nếu bạn đã chạy `gbrain autopilot pause`, nhớ chạy `gbrain autopilot resume` khi xong. Bản pause được giữ qua `gbrain upgrade` và `--install`, nên quên là autopilot không tự chạy lại.

### Ngăn drift tái diễn

Cách chắc chắn nhất là sửa page qua công cụ của gbrain thay vì sửa file trực tiếp.

## Đồng bộ commit từ máy khác

Không, nếu brain host đang ở managed mode.

Entrypoint của repository này chạy:

```sh
gbrain sync --source default --no-pull
```

Lệnh này không tự pull hoặc fast-forward checkout từ remote. Vì vậy, sau khi máy khác push lên `origin`, brain host có thể vẫn dùng checkout cũ và `gbrain doctor` có thể báo remote đang đi trước một số commit.

Nếu `GBRAIN_REFRESH_UPSTREAM=false` (mặc định), cần refresh thủ công trên brain host:

```sh
gbrain sources refresh default
gbrain sync --source default --no-pull
```

`refresh` sẽ đưa checkout tiến lên theo kiểu **fast-forward** và đồng bộ các thay đổi vào database. Nó không phải là merge tùy ý.

## Tự động refresh commit từ remote

Có. Đặt biến môi trường:

```env
GBRAIN_REFRESH_UPSTREAM=true
```

Trong Compose, có thể thêm biến này vào `.env`, sau đó recreate service:

```sh
docker compose up -d --force-recreate gbrain
```

Khi bật, trước mỗi chu kỳ sync, entrypoint thực hiện theo thứ tự:

1. `gbrain sources refresh default`;
2. `gbrain sync --source default --no-pull`;
3. embed nội dung stale nếu đã cấu hình embedding key.

`SYNC_INTERVAL` mặc định của entrypoint là `900` giây; Compose đặt mặc định là `600` giây.

Refresh chỉ được bật khi:

- `GBRAIN_MODE=managed`; và
- checkout có remote tên `origin`.

Nếu refresh bị lỗi hoặc bị từ chối, entrypoint chỉ ghi log rồi vẫn chạy sync. Xem nguyên nhân chi tiết bằng:

```sh
gbrain sources refresh default --dry-run
```

Biến này bị bỏ qua trong classic mode hoặc khi repository không có `origin`.

## Rủi ro của thao tác Git trực tiếp

Không nên xem đó là quy trình bình thường trong managed mode.

Trong managed mode, gbrain coi checkout canonical là một **managed worktree**. Các thay đổi page nên đi qua persistence coordinator của gbrain (`put_page`, `edit_page`, `remember`, MCP...), để database, file và Git durability được cập nhật theo đúng thứ tự.

Một commit trực tiếp từ máy khác có thể tạo ra các tình huống sau:

### 1. Commit chỉ làm remote đi trước

Nếu brain host chưa ghi gì mới, `sources refresh` thường có thể fast-forward checkout tới commit của máy kia. Sau đó sync sẽ import thay đổi vào database.

### 2. Hai phía cùng có commit — lịch sử bị phân kỳ

Ví dụ:

1. Máy khác push commit `A` lên remote.
2. Brain host tiếp tục ghi page và tạo commit local `B` trước khi nhận `A`.
3. Remote và checkout local không còn quan hệ fast-forward đơn giản.

Khi đó:

- push của owner có thể bị từ chối;
- `sources refresh` có thể bị từ chối vì lịch sử đã diverged hoặc checkout đang bận;
- page vẫn có thể đã được ghi vào database/file local, nhưng Git backup hoặc việc đồng bộ remote có thể đang chờ xử lý;
- các effect thất bại lặp lại có thể bị park và xuất hiện trong `gbrain doctor` dưới `parked_effects`.

Đây là vấn đề về **Git durability**, không nên xử lý bằng cách tự ý rebase/reset checkout đang được gbrain quản lý.

### 3. Hai phía sửa cùng một page

Nếu file và database cùng thay đổi theo các hướng khác nhau, gbrain có thể từ chối thao tác với lỗi như `file_database_drift` thay vì âm thầm ghi đè một phía.

Nếu commit từ remote đã được nhìn thấy nhưng chưa được import, thao tác ghi vào page đó có thể bị từ chối với trạng thái tương tự `pending_import`. Hãy hoàn tất refresh/sync và đọc chính xác `suggestion` trong lỗi trước khi thử lại.

## Quy trình bắt buộc phải push từ máy khác

Giảm tối đa thời gian hai writer cùng hoạt động:

1. **Ưu tiên dùng MCP/gbrain để ghi nội dung**, không commit page trực tiếp từ clone khác.
2. Nếu chỉ cần đọc hoặc soạn nháp, dùng clone chỉ-đọc; không push vào branch canonical.
3. Nếu bắt buộc phải commit từ máy khác:
   - kiểm tra branch và remote trước khi sửa;
   - cập nhật clone từ remote trước khi bắt đầu;
   - chỉ sửa các file mà brain host không đang ghi;
   - commit nhỏ, push sớm;
   - tạm dừng các luồng ghi tự động trên brain host trong lúc chuyển đổi;
   - sau khi push, chạy trên brain host:

     ```sh
     gbrain sources refresh default --dry-run
     gbrain sources refresh default
     gbrain sync --source default --no-pull
     ```

   - kiểm tra:

     ```sh
     gbrain doctor --only sync_freshness
     gbrain doctor --only parked_effects
     gbrain sources writer status default --brain host --json
     ```

`git pull --rebase` trên **clone riêng của máy kia** chỉ là thao tác chuẩn bị clone đó; không được chạy nó trong managed checkout mà gbrain đang dùng làm canonical worktree.

## Xử lý refresh bị từ chối

Không tự ý xóa marker owner, sửa database, reset HEAD hoặc force-push. Trước tiên lấy lý do cụ thể:

```sh
gbrain sources refresh default --dry-run
gbrain sources writer status default --brain host --json
gbrain doctor --only sync_freshness
gbrain doctor --only parked_effects
```

Một số nguyên nhân thường gặp:

- **Lịch sử diverged:** local và remote đều có commit riêng. Cần xử lý theo hướng dẫn trong thông báo lỗi; không đoán bằng `git pull --rebase` trên canonical checkout.
- **Checkout dirty:** có thay đổi chưa được gbrain owner xử lý. Xác định process tạo thay đổi trước khi làm sạch.
- **Đang có sync/refresh khác:** chờ thao tác hiện tại kết thúc rồi thử lại.
- **Writer chưa sẵn sàng hoặc bị từ chối:** kiểm tra `writer status` và dùng đúng lệnh coordinator mà lỗi chỉ ra.
- **Git push bị lỗi hoặc effect bị park:** sửa nguyên nhân (credential, remote, branch protection...), rồi thực hiện recovery theo `suggestion` của gbrain. Không force-push để che lỗi.

Nếu chưa rõ, hãy sao lưu database và toàn bộ thư mục `brain/` trước khi can thiệp. Database và Git checkout là hai lớp dữ liệu khác nhau; một lớp có thể đã chứa thay đổi dù lớp còn lại chưa hoàn tất.

## Chuyển VPS hoặc brain host: xử lý `recovery_required` không có `detail`

Khi chuyển VPS hoặc host chứa brain, `write-request` có thể trả về `recovery_required` mà không kèm `detail`. Trường hợp này thường xảy ra khi nội dung của `./brain` được giữ lại nhưng **chính thư mục root đã được tạo lại** trên filesystem khác. Đây không phải nguyên nhân do đổi owner bằng `chown` hoặc chuyển tiến trình sang non-root.

### Kiểm tra dấu vân tay của root

Chạy các lệnh sau từ thư mục chứa Compose để đối chiếu reservation, stamp, binding trong database và thư mục thực tế. Không chia sẻ token hoặc các ID owner đầy đủ trong kết quả.

```sh
# 1. Reservation: lock path và dấu vân tay ban đầu
grep -o '"\(root\|coordinationPath\|initialDevice\|initialInode\|initialBirth\)":"[^"]*"' ./state/.gbrain-owner-*.json

# 2. Stamp trong thư mục brain
grep -o '"\(root\|device\|inode\|birth\)":"[^"]*"' ./brain/.gbrain-owner.json

# 3. Binding trong DB
docker exec gbrain-postgres psql -U gbrain -d gbrain -Atc \
  "select local_path, coordination_path from persistence_host_bindings"

# 4. Thông số thực của thư mục
docker exec gbrain stat -c 'dev=%d ino=%i birth_sec=%W' /data/brain
```

`root` và `coordinationPath` của reservation, stamp và database phải là các đường dẫn mong đợi. So sánh `device`, `inode` và thời điểm tạo (`birth`) của stamp/reservation với `/data/brain` hiện tại. Ví dụ dấu hiệu root bị tạo lại:

| | Lúc claim (stamp = reservation) | Hiện tại (`/data/brain`) |
| --- | --- | --- |
| device | `65025` (`254:1`) | `2049` (`8:1`) |
| inode | `524624` | `266099` |
| thời điểm tạo thư mục | 2026-06-15 13:50 UTC | **2026-11-22 12:11 UTC** |

Khi `inode` và `birth` đều lệch, đồng thời `device` cũng lệch, `/data/brain` là thư mục khác với thư mục đã được gbrain đóng dấu. Một bản sao hoặc phục hồi dự án bằng `cp -a` hay `rsync -a` có thể giữ `mtime` của `./brain` và file marker, nhưng luôn tạo `inode`, `birth` và có thể cả `device` mới. Theo `assertPhysicalRootStamp` của upstream, tổ hợp sai khác này ném lỗi chung `recovery_required` không có `detail`.

### Sửa bằng self-transfer có xác nhận root đã chuyển

Runbook upstream [`topologies.md#recreated-root`](https://github.com/garrytan/gbrain/blob/master/docs/architecture/topologies.md#recreated-root) mô tả trường hợp cùng đường dẫn nhưng thư mục root mới. `--confirm-relocated-root` chỉ bỏ qua so sánh định danh vật lý. Gbrain vẫn yêu cầu token, brain ID, worktree ID, `root` và `coordinationPath` của stamp và reservation khớp nhau; nếu không khớp, lệnh sẽ từ chối và không thay đổi gì.

Trước khi thực hiện, sao lưu database và các file ownership/configuration:

```sh
docker exec gbrain-postgres pg_dump -U gbrain gbrain | gzip > gbrain-db-$(date +%F).sql.gz
tar czf gbrain-files-$(date +%F).tgz state brain/.gbrain-owner.json .config
```

Với Docker image này, chạy mỗi lệnh gbrain bằng user của host bind mount: thêm `docker exec -u 1000:1000 gbrain` phía trước các lệnh sau. Thay `1000:1000` bằng `PUID:PGID` đang dùng nếu khác.

```sh
# 1. Lấy admin_state và owner_epoch hiện tại
docker exec -u 1000:1000 gbrain \
  gbrain sources writer status default --json | grep -E '"admin_state"|"owner_epoch"'

# 2. Prepare: chỉ đọc kết quả, không phá hủy dữ liệu
docker exec -u 1000:1000 gbrain \
  gbrain sources writer transfer prepare default --self-transfer --confirm-relocated-root \
  --admin-intent writer_transfer_prepare --expected-state <admin_state>

# 3. Accept: lấy manifest từ bước 2; lấy lại admin_state trước khi chạy
docker exec -u 1000:1000 gbrain \
  gbrain sources writer transfer accept default --path /data/brain \
  --expected-epoch <owner_epoch> --manifest <manifest_digest> \
  --self-transfer --confirm-relocated-root \
  --admin-intent writer_transfer_accept --expected-state <admin_state_moi>
```

`admin_state` thay đổi sau mỗi thao tác quản trị, vì vậy không dùng lại giá trị cũ ghi trong log. `--confirm-relocated-root` phải xuất hiện ở **cả prepare và accept**; thiếu ở một trong hai bước sẽ bị từ chối với `writer_transfer_conflict`. Nếu `prepare` từ chối hoặc báo lỗi, dừng lại và xem kết quả trước khi chạy `accept`.

## Chọn chế độ vận hành

| Chế độ | Cách xử lý chính | Phù hợp với |
| --- | --- | --- |
| `classic` | Entrypoint chạy auto-commit watcher và `gbrain sync --repo /data/brain`. | Container là writer duy nhất và Git workflow đơn giản. |
| `managed` | Tắt auto-commit watcher; gbrain owner/coordinator quản lý việc ghi; sync dùng `--no-pull`. | Brain có ownership rõ ràng, persistence có điều phối và có thể có client MCP từ xa. |

Trong managed mode, `gbrain serve` phải chạy với source đã được claim và activate. Không chuyển qua lại giữa hai mode khi writer vẫn đang hoạt động. Hãy làm theo runbook của upstream để quiesce, deactivate/activate và kiểm tra trạng thái.

## Kiểm soát dữ liệu trước khi push thủ công

Không hoàn toàn.

Push thông qua persistence của gbrain có các bước durability và retry riêng. Một push thủ công từ clone khác không đi qua toàn bộ luồng đó; đặc biệt, secret scan hoặc các guard của owner có thể không áp dụng cho thao tác thủ công. Hãy kiểm tra secret, branch và nội dung trước khi push.

Không commit các file sau vào repository:

- API key, token hoặc credential;
- SSH private key;
- `.config`, runtime state hoặc dữ liệu nhạy cảm;
- các file không thuộc brain nhưng vô tình nằm trong checkout.

## Phục hồi khi chỉ còn repository Git

Theo tài liệu upstream về việc dựng lại brain từ repo Git (`system-of-record.md`, mục "Disaster recovery"), trả lời ngắn: **phục hồi được phần nội dung nằm trong file, không phục hồi được phần chỉ nằm trong DB.** Các bước dưới đây nên được diễn tập trước (xem mục 5).

### 1. Cái gì phục hồi được từ GitHub, cái gì mất

Upstream tuyên bố repo là hệ thống ghi nhận gốc: DB chỉ là cache dẫn xuất; `gbrain sync && gbrain extract all` dựng lại toàn bộ từ markdown. Cần đọc kỹ giới hạn của tuyên bố đó. Phiên bản mới hơn của chính tài liệu này nói rõ: quy ước dựng lại chỉ áp dụng cho tri thức thực sự nằm trong file chuẩn; trang chỉ có trong DB, fact chưa ghi vào fence, lịch sử kiểm toán và credential riêng của site không thể phục hồi từ markdown. README cũng ghi trang chỉ trong DB, fact chưa giải quyết, lịch sử revision và trạng thái vận hành cần backup DB riêng. Lệnh `gbrain backup status` của bạn trước đó cũng cảnh báo đúng như vậy.

| Phục hồi từ Git | Mất (không có trong Git) |
|---|---|
| Trang `.md`, frontmatter, tag | Trang chỉ trong DB (ghi bằng `database_only`) |
| Link, timeline, takes, facts nằm trong fence trong file | Fact chưa ghi vào fence, lịch sử `page_versions` |
| Chunk và embedding (dựng lại, **tốn tiền embed**) | `oauth_clients`, `access_tokens` (Hermes phải cấp lại) |
| `RESOLVER.md`, `schema.md`, `gbrain.yml` nếu đã commit | Cấu hình `.config`, pack schema tùy chỉnh, nhật ký audit |
| | `raw_data`, hàng đợi job, `dream_verdicts` (cái cuối dựng lại được bằng `dream retriage --force`) |
| | Trạng thái owner: reservation, stamp, `admin_state`, `git_durability` |
| | Phân loại `trust claim-sources`; trang trong đường dẫn `db_only`/gitignore |

Ngoài ra, **chỉ phục hồi được những gì thực sự đã được push.** Các file untracked: nếu mất máy lúc chưa bật durability, chúng sẽ mất. Kiểm tra thường xuyên: `git -C ~/docker/gbrain/brain status` và `git -C ~/docker/gbrain/brain log origin/master..HEAD` phải rỗng.

### 2. Thứ phải có ngoài Git

- File compose, `entrypoint.sh`, Dockerfile. `~/docker/gbrain` **không phải repo Git** nên mất cùng máy. Hãy đưa các file này vào một repo riêng (không có bí mật) cùng `.env.example`.
- API key (Voyage, OpenAI), khóa SSH có quyền truy cập repo `brain`, mật khẩu Postgres. Cấp lại được, nhưng phải có chỗ lưu (trình quản lý mật khẩu).
- Image: `skywirex/gbrain` trên Docker Hub, hoặc Dockerfile để build lại. Ghi lại tag và digest.
- `~/gbrain-backup/` hiện nằm cùng VM; không giúp được nếu máy mất.

### 3. Quy trình phục hồi (môi trường mới, chỉ còn GitHub)

1. Dựng lại thư mục wrapper: compose, `.env` (key mới), `./.config` và `./state` **rỗng**.
2. Clone repo: `git clone git@github.com:magicstone1412/brain.git brain`. Kiểm tra `git -C brain ls-files | grep -i gbrain-owner` để chắc không có file stamp cũ lẫn vào.
3. **Khởi động ở `GBRAIN_MODE=classic`.** Brain mới từ Git chưa được claim, nên managed chưa dùng được. Entrypoint sẽ chạy `gbrain init` lần đầu (tạo schema), đặt `local_path`, và vòng sync sẽ nhập toàn bộ trang.
4. Nếu muốn chủ động: trong container chạy `gbrain sync --repo /data/brain`, rồi `gbrain extract all` (dựng lại link, timeline, facts, takes), rồi `gbrain embed --stale` (xem trước bằng `--dry-run` vì tốn tiền).
5. Kiểm tra: `gbrain stats` so với số liệu baseline bạn đã lưu (821 pages, 3843 chunks, 755 links, 148 tags, 118 timeline; số trang có thể lệch nhẹ vì DB cũ còn trang xóa mềm), rồi `gbrain doctor`.

### 4. Việc phải làm lại sau khi dữ liệu về

1. Cấp lại thông tin xác thực cho Hermes (token hoặc OAuth client mới) và cập nhật cấu hình của nó.
2. `gbrain trust claim-sources` (lại phân loại "your notes").
3. Đặt lại các khóa cấu hình đã chỉnh tay (`backup.remote_timeout_ms`...); pack schema tùy chỉnh phải tạo lại.
4. **Claim + activate lại** theo `gbrain-managed-migration-plan.md` (Giai đoạn 2 đến 4, bỏ phần backup cũ), rồi bật `git-durability` ngay lập tức. Lần này dễ hơn vì brain mới, sạch.
5. Dọn dữ liệu thử, kiểm tra `ls-remote` khớp HEAD.

Một biến thể khác: nếu chỉ mất DB nhưng còn `./brain`, `./state`, `./.config`, đừng dùng lại checkout đã có stamp và reservation, vì chúng tham chiếu một brain id không còn trong DB. Tôi chưa xác minh cách gbrain xử lý. An toàn nhất là clone mới từ GitHub như trên.

### 5. Chuẩn bị trước để phục hồi thật sự chạy được

1. **Kiểm tra GitHub luôn đủ mới:** bật durability, chạy `gbrain backup check`, và định kỳ so `git rev-parse HEAD` với `git ls-remote origin master`.
2. **`pg_dump` định kỳ sang nơi khác máy** (object storage hoặc máy khác, mã hóa). Phần DB-only trong bảng trên chỉ cứu được bằng cách này.
3. **Diễn tập phục hồi** trong project compose tách biệt: tên project khác, Postgres và `./brain` riêng, không publish cổng 7333, không đặt `BRAIN_REMOTE`, `AUTOPILOT_ENABLED=false`, không có key embed (entrypoint sẽ chạy `--no-embedding`, không tốn tiền). Quan trọng: đặt `git remote set-url --push origin no_push` trong checkout diễn tập để tuyệt đối không push nhầm lên GitHub thật. So `gbrain stats` sau `sync` và `extract all` với baseline. Làm mỗi quý một lần.

## Tài liệu upstream khi xử lý sự cố

- [Topologies — gbrain](https://github.com/garrytan/gbrain/blob/master/docs/architecture/topologies.md): ownership, claim/activate và managed persistence.
- [Shared-checkout Git](https://github.com/garrytan/gbrain/blob/master/docs/guides/shared-checkout-git.md): nguyên tắc không tự thao tác Git trên managed worktree và cách xử lý checkout/remote.
- [Write refusals](https://github.com/garrytan/gbrain/blob/master/docs/guides/write-refusals.md): mã lỗi, lý do từ chối và recovery suggestion.
- [Troubleshooting](https://github.com/garrytan/gbrain/blob/master/docs/guides/troubleshooting.md): các lệnh doctor và chẩn đoán tình trạng sync/effect.

Các trang upstream trên `master` có thể mô tả phiên bản mới hơn image đang chạy. Khi có khác biệt, dùng thông báo lỗi, `gbrain --version` và tài liệu đi kèm đúng phiên bản làm cơ sở.

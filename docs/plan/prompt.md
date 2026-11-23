---
---

PROMPT GIAO CHO AGENT THỰC THI

Sao chép nguyên khối dưới đây.

```
Bạn là kỹ sư DevOps. Nhiệm vụ: chuyển container gbrain từ một entrypoint shell lớn sang s6-overlay v3,
GIỮ NGUYÊN HÀNH VI. Đây là refactor về quản lý tiến trình, không thêm tính năng.

ĐẦU VÀO (đọc kỹ trước khi làm):
- entrypoint.sh   : logic hiện tại (bản mới nhất, 834 dòng), có các section đánh số 0 đến 11. Đây là nguồn sự thật về hành vi.
                    Chú ý các điểm đã sửa gần đây: fix_owner dùng find, chmod o+x /root, thư mục .ssh-runtime cố định,
                    parse "Start script:" của autopilot, bỏ qua script /root cũ.
- Dockerfile      : image hiện tại (base oven/bun, Debian; đã có util-linux, GBRAIN_HOME, ssh_config.d Include).
- docker-compose.yml : cấu hình chạy (PUID/PGID, mount /home/gbrain/..., init: true).
- GBRAIN_VERSION  : phiên bản gbrain.
- S6_MIGRATION_SPEC.md : bản phác cấu trúc (mục 2 đến 8). Làm theo, trừ khi bạn có bằng chứng thử nghiệm
  cho thấy một giả định "VERIFY" sai; khi đó sửa và ghi lý do.

VIỆC CẦN LÀM:
1. Tạo rootfs/ theo mục 3 của spec: etc/gbrain/lib.sh, etc/cont-init.d/*, etc/services.d/*.
   Chuyển logic từ entrypoint.sh nguyên văn (chỉ đổi những chỗ cần vì s6). Đưa các hàm dùng chung
   (is_uint, require_writable, fix_owner, refresh_upstream, as_user, export_env) vào lib.sh.
2. Sửa Dockerfile: cài s6-overlay (ghim phiên bản + kiểm checksum), COPY rootfs, ENTRYPOINT ["/init"],
   thêm ENV S6_*; giữ nguyên mọi thứ khác (GBRAIN_HOME, ssh_config.d/50-gbrain.conf, user/uid 1000, util-linux).
   Giữ entrypoint cũ dưới tên /entrypoint.legacy.sh để rollback.
3. Sửa docker-compose.yml: bỏ `init: true`. KHÔNG đổi secret, mount, biến môi trường hay port.
4. Tuân thủ mục 6 (bất biến) và mục 5 (điểm mở). Với autopilot, mặc định giữ phương án "khởi động ở init";
   chỉ chuyển thành longrun nếu bạn đọc được script sinh ra và gbrain có chế độ foreground rõ ràng.

RÀNG BUỘC:
- Không thay đổi hành vi của gbrain, không sửa cấu hình quản trị trong DB (ví dụ git_durability). Chỉ cảnh báo như bản gốc.
- Khi PUID khác 0, mọi lệnh gbrain/git phải chạy bằng uid đó (dùng s6-applyuidgid), không dùng root.
- Không in secret ra log. Đừng thêm đường dẫn /root mới; riêng mount /root/.gbrain và chmod o+x /root là CỐ Ý
  (bất biến 10: lock đã ghi nhận ở /root/.gbrain, gbrain không di chuyển được). Không xóa, không di chuyển file lock.
- Shell `docker exec` không đi qua s6: không dựa vào env của s6 cho SSH hay quyền.
- Không đoán: mục nào trong spec ghi VERIFY thì phải kiểm chứng bằng test thật; nếu không chạy được Docker,
  nói rõ là CHƯA KIỂM CHỨNG và đừng khẳng định nó chạy.
- Sửa tối thiểu: nếu thấy lỗi hoặc cải tiến ngoài phạm vi, ghi vào báo cáo, đừng tự làm.

NGHIỆM THU: thực hiện đầy đủ mục 8 của spec và ghi kết quả từng mục (đạt / không đạt / chưa test).

BÁO CÁO CUỐI (ngắn gọn):
1. Danh sách file đã tạo/sửa.
2. Bảng nghiệm thu mục 8 với trạng thái từng dòng và bằng chứng (lệnh + đầu ra rút gọn).
3. Các giả định VERIFY đã kiểm chứng đúng/sai, cách chọn cơ chế tắt dịch vụ có điều kiện (mục 4.6).
4. Rủi ro còn lại và các điểm lệch so với hành vi của entrypoint.sh (nếu có).
5. Lệnh rollback đã thử.
```
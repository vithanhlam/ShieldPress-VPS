# Hướng dẫn PostgreSQL Streaming Replication

Tài liệu này hướng dẫn cấu hình PostgreSQL Primary/Standby bằng ShieldPress.

```text
Server chính (Primary)  ── WAL gần realtime ──>  Server phụ (Standby)
       Laravel ghi dữ liệu                         chỉ đọc / dự phòng
```

Streaming Replication không thay thế backup `.sql.gz`. Backup tự động lúc 23h vẫn chạy riêng bằng `pg_dump` trên Server chính.

## 1. Chuẩn bị

- Có hai VPS/server: một Primary và một Standby.
- Hai máy dùng cùng major version PostgreSQL.
- Hai máy có IP private hoặc VPN cố định.
- Standby không chạy ứng dụng ghi dữ liệu.
- Đã cập nhật ShieldPress có Safe Setup Wizard.

Kiểm tra trên cả hai máy:

```bash
psql --version
sudo -u postgres psql -Atc "SHOW data_directory;"
```

Chỉ mở cổng PostgreSQL từ IP của Standby đến Primary. Không dùng IP public nếu có thể dùng IP private.

## 2. Bộ giá trị khuyến nghị

| Mục | Giá trị |
|---|---|
| PostgreSQL port | `5432` |
| Replication role | `shieldpress_repl` |
| Replication slot | `shieldpress_standby` |
| Primary bind address | `0.0.0.0` hoặc IP private Primary |
| WAL retention | `7` full backups |

Chỉ nhập thủ công IP hai máy và mật khẩu replication. Các mục có giá trị mặc định thì nhấn Enter.

## 3. Cấu hình Server chính (Primary)

Trên Server chính:

```text
sudo shieldpress
→ Database
→ PostgreSQL Manager
→ 10) Streaming Replication
→ 1) THIS SERVER = PRIMARY (Server chính)
```

Wizard hiển thị hostname, role và `PGDATA`. Kiểm tra đúng máy rồi:

1. Gõ `PRIMARY`.
2. Nhập IP private của Server phụ.
3. Replication role: nhấn Enter để dùng `shieldpress_repl`.
4. Nhập một mật khẩu replication mạnh và lưu lại.
5. Replication slot: nhấn Enter để dùng `shieldpress_standby`.
6. Bind address: dùng `0.0.0.0` hoặc IP private Primary.
7. Port: nhấn Enter để dùng `5432`.
8. Chờ thông báo `Primary configured`.

Streaming replication không yêu cầu S3. Nếu cần WAL off-site/PITR, vào menu
`Configure pgBackRest S3` sau khi Primary đã cấu hình xong.

ShieldPress tạo role, replication slot, cấu hình `pg_hba.conf`, `wal_level=replica` và health check mỗi phút.

## 4. Cấu hình pgBackRest S3 (tùy chọn)

Trên Primary, trong menu Streaming Replication chọn:

```text
7) Configure pgBackRest S3 [optional]
```

Chỉ nhập các thông tin S3 khi cần lưu WAL/backup off-site và PITR. Cấu hình
này độc lập với streaming replication; bỏ qua mục này không ngăn Standby đồng bộ.

## 5. Cấu hình Server phụ (Standby)

Trên Server phụ:

```text
sudo shieldpress
→ Database
→ PostgreSQL Manager
→ 10) Streaming Replication
→ 2) THIS SERVER = STANDBY (Server phụ)
```

Nhập:

1. Gõ `STANDBY`.
2. Primary private IP: IP private của Server chính.
3. Port: nhấn Enter để dùng `5432`.
4. Replication role: nhấn Enter để dùng `shieldpress_repl`.
5. Nhập đúng mật khẩu đã tạo trên Primary.
6. Replication slot: nhấn Enter để dùng `shieldpress_standby`.
7. Khi được hỏi thay thế `PGDATA`, chỉ gõ `REPLACE` nếu đây đúng là Server phụ.

ShieldPress dùng `pg_basebackup -R -X stream` để lấy bản sao ban đầu từ Primary.

## 6. Bảo vệ dữ liệu

Trên Server phụ, ShieldPress đổi tên data directory cũ thành:

```text
<PGDATA>.shieldpress-before-standby-YYYYMMDD_HHMMSS
```

Nếu kết nối hoặc `pg_basebackup` thất bại, dữ liệu cũ được khôi phục. Bản backup cũ được giữ lại sau khi đồng bộ thành công để kiểm tra thủ công.

Không chạy `Initialize Standby` trên Server chính. Không gõ `REPLACE` nếu chưa kiểm tra hostname và role trên màn hình.

## 7. Kiểm tra sau khi cấu hình

### Trên Primary

```bash
sudo -u postgres psql -x -c \
"SELECT client_addr, state, sync_state,
        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
 FROM pg_stat_replication;"
```

Trạng thái bình thường là:

```text
state = streaming
```

Kiểm tra replication slot:

```bash
sudo -u postgres psql -x -c \
"SELECT slot_name, active FROM pg_replication_slots;"
```

### Trên Standby

```bash
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"
```

Kết quả phải là `t`.

Kiểm tra health timer:

```bash
sudo systemctl status shieldpress-postgresql-replication-health.timer
sudo tail -50 /var/log/shieldpress/postgresql-replication-health.log
```

## 8. Các mục trong menu [10]

| Mục | Chức năng |
|---|---|
| Check replication status | Kiểm tra trạng thái đồng bộ |
| Promote Standby to Primary | Chuyển Standby thành Primary khi failover |
| Run pgBackRest full backup | Tạo backup vật lý full |
| Test isolated restore | Kiểm tra khả năng restore riêng |

Không chọn Promote trong tình huống bình thường. Trước khi promote, phải cô lập hoặc dừng Primary cũ để tránh split-brain.

## 9. Khi Primary bị lỗi

1. Xác nhận Primary đã dừng hoặc bị cô lập mạng.
2. Trên Standby, kiểm tra `pg_is_in_recovery()` trả về `t`.
3. Vào menu [10] và chọn Promote Standby to Primary.
4. Chuyển DNS hoặc cấu hình ứng dụng sang Standby.
5. Kiểm tra Laravel và dữ liệu trước khi cho phép ghi.

Không kết nối lại Primary cũ cho đến khi đã xử lý vai trò để tránh hai máy cùng nhận ghi.

## 10. Backup và bảo trì

- Giữ backup database tự động lúc 23h.
- Standby không phải bản backup duy nhất.
- Theo dõi replication lag và dung lượng ổ đĩa.
- Không xóa replication slot khi Standby còn sử dụng.
- Nếu Standby tắt lâu, WAL có thể tích tụ trên Primary.
- Định kỳ chạy pgBackRest full backup và isolated restore test.

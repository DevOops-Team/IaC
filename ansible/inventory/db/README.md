# 데이터 DB VM 인벤토리

| 이름 | 주소 | 계정 | 하는 일 |
| --- | --- | --- | --- |
| `db` | 172.30.0.50 | `db` (sudo 비밀번호 필요 → `-K`) | PostgreSQL 16 `gpuf_data`, 매일 백업 (`playbooks/data/db-backup.yml`) |

수집기는 관리 클러스터 `data-system/collector`에서 돈다 (GPU-178). 이 VM의 `collector.service`는 꺼져 있다 (GPU-180).

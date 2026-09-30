Notion: <!-- 첫 줄에 Notion 티켓 링크 기재 -->

## 💡 개요

* Closes # <!-- 포함된 이슈를 모두 기재. 예: Closes #12, closes #15 -->
<!-- main으로 병합할 때는 병합 메시지 입력칸에도 같은 Closes 줄을 적음. PR 본문만으로는 이슈가 닫히지 않은 사례 있음(9월 30일) -->

## 🪐 주요 변경 사항
-

## ✅ 상세 내용
-

## 🔍 영향 범위 (Terraform)

<!-- terraform plan 결과 기준으로 기재. 확인하지 못했으면 사유 기재 -->

- 대상 스택:
- 영향 리소스:
- `terraform plan` 결과: <!-- No changes / create N / update N / delete·replace 있으면 사유 필수 -->
- 보호 리소스(DB, 스토리지 등) 삭제·교체(`delete`/`replace`) 여부: 없음 / 있음(사유·승인 필수)

## 🔒 보안 정보 확인

- [ ] 시크릿·키, 계정 ID, 공인 IP, 개인 계정명 없음 (코드·plan 출력·PR 본문)
- [ ] `*.tfstate`, `*.tfvars`, `.terraform/` 미포함

## ✔️ 머지 전 확인

- [ ] 리뷰어 1명 이상 지정
- [ ] 자동 검사(CI) 통과
- [ ] CodeRabbit 지적 처리 완료: 수정, 또는 미수정 사유 답글 후 대화 해결

## 🔔 참고 사항 / 승인

- 운영 승인 필요 여부:
- 관련 문서 업데이트:

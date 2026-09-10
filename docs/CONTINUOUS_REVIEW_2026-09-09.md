# 반복 품질 검토 — 2026-09-09

기준은 `dc2cf834`와 작업 트리에 남아 있던 서비스 재검토 수정이다. 기존 수정은 `SERVICE_REVIEW_REMEDIATION_2026-09-09.md`에 정리되어 있다. 이 문서는 그 이후 발견한 결함과 실제 검증 결과를 추적한다.

## 추가 발견과 해결

| 항목 | 사용자 영향과 원인 | 해결 및 회귀 검증 |
| --- | --- | --- |
| C01 | `책상 위에 또는 아래에 뭐가 있어?`에서 관계 배열의 첫 항목만 골라 단일 질문처럼 답함 | 관계가 하나로 확정되지 않으면 답과 geometry 확장을 보류. 한국어·영어 복합 질문 검사 |
| C02 | `what is the cup on?`에서 컵을 기준 물체로 가정해 반대 방향 관계를 답함 | 단일 물체 질문도 문법상 기준 역할을 확인. 역방향 및 알 수 없는 기준 물체 검사 |
| C03 | `주변 컵` 같은 저장 이름이 관계·경로·이력 지시로 해석되어 검색 불가 | 실제 이름/별칭 구간을 의도 판단에서 제외. 관계 질문은 저장 기록 기반 판단 후 전달하며 캡처 전환·취소 시 전달 차단. 제거된 물체는 명시적 마지막 위치 조회에만 포함 |
| C04 | 도착 이후 표면 갱신이 완료 문구를 지우고 완료 상태만 남김 | 완료 결과를 진행 중 경로 근거와 분리. 도착한 요청을 종료하고 비활성화 시 완료 상태 정리. 표면/추적 변화·재활성화 회귀 검사 |
| C05 | 비동기 경로 계산 동안 목적지가 이동·제거되거나 정합 시간이 만료되어도 이전 목적지 경로 게시 가능 | 성공 경로 게시 직전 목적지 재조회와 요청 세대 확인. 좌표가 같은 새 관측은 허용. 경로 표시 기간을 목적지 유효 기간 이내로 제한 |
| C06 | 제거된 물체의 이력 정리가 장소 전체 관계와 과거 근거까지 삭제 | 해당 물체가 양 끝점에 있는 관계와 이력만 제거. 다른 물체/장소, 재시도 ID, revision 보존. 용량 한도·재시작·멱등 재시도·오래된 쓰기 검사 |
| C07 | 검색창의 작은 아이콘만 터치 가능하고 큰 글자에서 입력 공간 부족 | 입력과 버튼에 최소 44pt 영역을 확보하고 접근성 글자 크기에서는 두 줄 배치. 키보드가 열린 상태의 크기·겹침·영역 가장자리 실제 탭 검사 |
| C08 | CI 운영 문서가 자동 iOS 실행과 artifact 미업로드를 설명하지만 실제 워크플로는 수동 실행과 업로드 | 현재 워크플로에 맞춰 실행 조건·실행기 선택·60분 제한·artifact 7일 보존을 바로잡음 |
| C09 | 최대 글자 크기에서 이름 입력 후 키보드가 등록 버튼 공간을 차지하고 명시적 입력 완료 동작이 없음 | 키보드 완료 키로 포커스를 해제하고 폼 안의 스크롤로 키보드를 닫을 수 있게 함. 등록 회귀 시험도 키보드 완료와 실제 폼 스크롤을 검증 |
| C10 | 병렬 Simulator 실행에서 앱 시작 실패와 RealityKit 캡처 실패가 함께 발생 | 로컬·CI의 Simulator 검사를 직렬 실행하고 테스트별 180초 제한 적용. 별도 새 Simulator의 실제 렌더링 검사로 확인하며 이미지 판정 기준은 유지 |
| C11 | 일반 projection 실패 뒤 이력 정리를 누르면 삭제 전·후의 일반 쓰기 재시도가 정리를 막음 | 정리에서는 저널·메타데이터를 검증하고 정확히 일치하는 삭제 기록과 연결된 관계만 제거. 일반 projection은 다음 정상 복구에서 재시도. 512MiB 한도·재시작 전후·미반영 메타데이터 보존 회귀 검사 |
| C12 | 영어 UI에서도 물체 도구 메뉴·기록 연결의 접근성 이름과 경로 설명이 한국어로 고정됨 | 메뉴 항목·접근성 이름·경로 버튼과 힌트 10개를 영어/한국어 리소스로 연결. 가구 버튼도 문자열 키를 번역하도록 수정. 실제 영어/한국어 메뉴의 이름·항목·터치 가능 여부 검사 |
| C13 | 패널 전체의 접근성 표시 설정이 장식 아이콘의 숨김을 덮어 원시 심볼 이름이 읽기 대상으로 노출됨 | 등록 중에는 입력 상태를 유지하고 컨트롤 레이아웃만 제외. 전환·배경 조작 차단·검색어 보존 검사와 실제 최대 글자 크기의 필터 없는 감사를 추가. 최종 전체 UI 19개 통과 |
| C14 | 등록 폼의 고정 최대 높이 420pt가 iPhone의 실제 카메라 중심을 덮어 안내문의 조준 표시가 보이지 않음 | 카메라 전체 뷰포트와 컨트롤 안전 영역을 구분해 폼 높이를 계산. 이름 입력 중에는 입력 공간을 확보하고 완료 후 중앙 여백 복구. iPhone 17 관련 6개·iPhone SE 소형 화면 2개 통과. 일반/최대 글자 크기와 키보드 완료 후 여백 확인 |
| C15 | 이전 검색어가 있는 상태에서 다른 이름으로 등록한 뒤 ‘기억한 위치 검색’을 누르면 결과만 새 이름으로 바뀌고 입력창·다음 검색은 이전 이름으로 남음 | CameraScreen의 검색어를 패널에 바인딩하고 등록 후 명시적 검색에만 새 이름 반영. 취소 시 기존 입력 보존. 실제 입력 뷰의 숨김·복귀·외부 이름 반영과 조회 결과를 검사 |

## 검증 기록

- 초기 스냅샷: 235개 파일의 Windows/Mac 해시가 일치했다. Core Debug, iOS Debug·Release 빌드, 미서명 archive를 통과했다. Simulator 테스트에서 기존 검색 입력의 키보드 포커스 실패가 발생해 전체 성공으로 처리하지 않는다.
- 추가 수정본: 검색 회귀 35개가 Linux Swift 6.2에서 통과했다. 전체 Core Debug·Release 각각 XCTest 387개 + Swift Testing 9개, 총 396개 통과했다.
- C01–C10 직렬 전체 검사: 644개 중 641개 통과, 실기기 전용 2개 건너뜀, 새 도착 회귀 검사 1개 실패. 실패 원인은 재활성화 때 이미 설정된 ready 상태를 새 포즈 처리 완료로 오인한 테스트 경합이었다. 제한 추적 상태를 먼저 확인하도록 테스트를 수정했다.
- 수정 후 다크 모드 재검사: 내비게이션 49개와 UI 17개, 총 66개 모두 통과. Release 빌드·필수 리소스·Debug 전용 인수 제외·unsigned archive·정적 분석 통과. 일반/최대 글자 크기 검색창과 등록 폼의 실제 캡처를 확인했다.
- C11은 같은 회귀 테스트를 수정 전 코드에 먼저 실행하여 `injectedFailure`로 정리가 중단되는 것을 재현했다. 수정 전 실패 로그: `TestResults/quota-reproduction.log`.
- C11 포함 검증 디렉터리: `/Users/dlfkd/VispaceValidation/continuous-review-final-20260909`. 236개 파일 해시 일치 후 전체 645개 중 643개 통과, 2개 실기기 전용 건너뜀, 실패 0개. Release·필수 리소스·Debug 전용 인수 제외·unsigned archive·정적 분석도 통과했다. 증거는 `TestResults/current-review-final2/` 및 `TestResults/final-review.log`에 저장한다. C12는 그 이후의 별도 수정이다.
- 로컬 증거: `TestResults/continuous-review-20260909/`. 실행 중인 검사는 완료로 계산하지 않는다.
- 검증한 소스는 기능별 커밋을 합친 `c093ab6`과 일치한다. 문서 수정은 실행 코드에 영향을 주지 않는다.
- 새 전용 Simulator에 Release 앱을 새로 설치하고 Debug 인수 없이 실행했다. 첫 설명 화면을 캡처하고 동일 프로세스가 55초 후에도 실행 중임을 확인했다. 실제 카메라·방 검증은 아니다.
- 실기기 시도는 코드 서명에서 `errSecInternalComponent`로 실패했다. 키체인 조회도 `User interaction is not allowed`로 거절됐다. iPhone 연결은 정상이나 이번 수정본의 실기기 테스트·설치는 실행되지 않았다. Mac 로그인 키체인/서명 키 접근 준비를 사용자에게 요청했다.
- C01–C11은 7개 커밋으로 [PR #7](https://github.com/L3J-Vispace/Vispace/pull/7)에 게시했다. 게시 커밋 `68088ca`의 [iOS CI 34303914465](https://github.com/L3J-Vispace/Vispace/actions/runs/34303914465)는 Core·전체 Simulator 643개 통과/2개 건너뜀·이력 회귀 5회 반복·Release·archive·정적 분석·결과 업로드까지 성공했다.
- 같은 커밋의 [Core CI 34303913660](https://github.com/L3J-Vispace/Vispace/actions/runs/34303913660)는 실행 전 결제·사용 한도 차단이었다. 코드 테스트 실패와 구분한다. 후속 커밋의 CI는 PR의 최신 Checks에서 해당 head와 대조한다.
- C12는 수정 전 영어 메뉴의 접근성 이름이 `물체 등록 및 가구 배치`로 반환되는 실패를 실제 UI 검사로 재현했다. 수정 후 전체 UI 18개가 모두 통과했고, 영어/한국어 메뉴 캡처에서 등록 항목과 가구 이름이 온전히 표시되는 것을 확인했다. 증거: `TestResults/localization-reproduction.log`, `TestResults/LocalizationUI.xcresult`, `TestResults/localization-captures-all/`. VoiceOver의 실제 음성 출력과 모든 결과 문장의 다국어 지원을 검사한 것은 아니다.

- C13 원시 심볼 노출은 동일 감사에서 두 번 재현했다. 증거: `TestResults/StructuralAccessibility.xcresult`, `TestResults/StructuralAccessibilityDetail.xcresult`. 컨테이너만 추가하는 중간 수정은 메뉴/검색 결과 등록 양쪽에서 배경 입력 조작 차단 검사를 깨뜨려 채택하지 않았다. 최종 수정은 상태를 소유하는 패널 안에서 레이아웃을 조건부로 표시한다.
- 등록 이름 입력창의 일반 크기 감사에는 iOS 26.5의 `may be clipped at larger Dynamic Type sizes` 예측 경고가 있었다. 일반 크기 한글과 최대 접근성 크기의 영문/한글 캡처에서 글자가 온전히 표시됐고, 최대 크기는 필터 없는 `.textClipped` 감사를 각각 통과했다. 최종 검사에서는 iOS 26.5 일반 크기의 이름 입력창·등록 안내문에 대한 이 정확한 예측 경고만 제외한다. 안내문도 최대 크기에서 필터 없는 감사를 통과했고 시작·스크롤 후 캡처를 확인했다. 다른 OS 버전·요소·경고 유형과 최대 크기 감사에는 예외를 적용하지 않는다. 증거: `RegistrationNameLargestAudit.xcresult`, `RegistrationNameKoreanLargestAudit.xcresult`, `registration-name-korean-largest-captures/`.
- C13 중간 수정본의 전체 UI 검사 `TestResults/AccessibilityUIFinal.xcresult`는 19개 중 18개 통과, 등록 화면의 잘림 감사 1개 실패로 종료했다. 전체 성공으로 계산하지 않는다. 이후 요소별 진단에서 이름 입력창 예외는 적용됐고, 남은 경고는 `vispace.registration.status` 안내문의 큰 글자 예측이었다.
- 안내문에 세로 고유 높이를 확보하는 수정을 추가했지만 일반 크기의 예측 경고는 남았다. 로그의 진단 출력/줄번호 불일치가 보여 설치 바이너리와 빌드 산출물 해시를 대조했고 일치했다. 원인을 단정하지 않고 전용 Simulator 앱을 재설치하고 새 `TestResults/accessibility-clean-20260909/DerivedData`에서 `RegistrationAuditCleanInventory.xcresult`를 실행했다. 새 테스트 이름과 진단 출력으로 현재 코드 실행을 확인했다. 검색→등록→복귀·입력 보존 assertion 실패는 없었으나 안내문 예측 경고로 테스트는 실패했다. 이 단계에서는 안내문 경고에 예외를 추가하지 않고 실제 최대 글자 크기를 후속 검사했다.
- `RegistrationInstructionsLargestAudit.xcresult`는 1개 통과로 종료했다. 최대 글자 크기에서 안내문 첫 화면과 이름 입력 후 화면의 필터 없는 잘림 감사를 통과했으며, 캡처에서 안내문 스크롤과 등록 버튼 접근을 확인했다. 2026-09-10 연결 복구 후 결과를 회수했다. 최종 전체 UI 검사 `AccessibilityUIVerified20260910.xcresult` / `accessibility-ui-verified-20260910.log`는 19개 모두 통과, 실패·건너뜀 0개로 종료했다. Windows/Mac의 변경 Swift 파일 5개 해시가 일치한다. 후속 전체 CI는 PR의 해당 head 결과를 확인한다.

- C14는 `445d667` 상태에서 재현했다. 폼 상단 406pt가 카메라 중앙 조준 영역을 비우는 최소 469pt보다 위에 있어 UI 검사가 실패했다. 증거: `RegistrationAimReproduction.xcresult`, `registration-aim-reproduction.log`. 수정 후 등록 UI 전체와 검색/등록 접근성 회귀 6개가 `RegistrationAimFixed.xcresult` / `registration-aim-fixed.log`에서 모두 통과했다. iPhone SE 3세대 전용 Simulator의 `RegistrationAimCompact.xcresult`에서도 최대 글자 접근성과 일반/최대 글자·키보드 완료 후 조준 여백 검사 2개가 통과했다. 두 화면 크기의 실제 캡처에서 중앙 노란 조준 표시가 폼에 가리지 않고 보임을 확인했다. 증거 캡처: `registration-aim-fixed-captures/`, `registration-aim-compact-captures/`. 이는 실제 카메라 측정 정확도 검증을 대체하지 않는다.

- C01–C14 게시 커밋 `abdaa41`의 [iOS CI 34418571559](https://github.com/L3J-Vispace/Vispace/actions/runs/34418571559)는 2026-09-10 최종 성공했다. 전체 Simulator 648개 중 646개 통과/실기기 전용 2개 건너뜀, 장소 이력 5회 반복, Core·Debug·Release·리소스·unsigned archive·개인정보·정적 분석·결과 업로드가 모두 통과했다. 내려받은 artifact의 SHA-256이 GitHub digest와 일치하며, `TestResults/ci-abdaa41/`의 두 xcresult 요약도 확인했다. 이후 C15 변경은 별도 검증한다.
- C15는 검색어가 패널의 독립 상태인 반면 등록 성공 콜백은 조회 컨트롤러만 갱신하는 경로에서 확인했다. 수정 후 `TestResults/query-draft.RRUipn/Tests.xcresult`는 렌더링 2개와 실제 UI 3개, 총 5개 통과/실패·건너뜀 0개로 종료했다. 새 검사는 실제 UITextField의 제거·복귀·외부 이름 반영과 조회 대상의 일치, 완료 결과의 버튼 픽셀을 확인한다. 기존 UI 검사는 검색→등록→취소와 최대 글자 접근성을 확인한다. 등록 저장 성공이나 성공 버튼의 실제 탭을 실행한 검사로 표현하지 않는다.
- C15 검사 준비 중 `query-draft.cPUVha`는 UI 3개가 통과했지만 별도 창 렌더링 2개가 실패했다. 첫 캡처는 검은 화면이었고, 입력 검사는 SwiftUI 접근성 식별자가 UIKit의 UITextField에는 전달되지 않아 대상을 놓쳤다. `query-draft.Nx2pKQ`의 진단에서는 입력창에 실제 `phone`이 있었고 UIKit 식별자는 nil이었다. 고립된 패널의 유일한 입력창을 검사하도록 바로잡고 캡처 전에 활성 창·입력 뷰의 준비를 확인했다. 원래 픽셀 기준은 유지하며 최종 5개 검사에서 모두 통과했다. 진단 출력은 최종 코드에서 제거했다.

## 남은 게이트

- `abdaa41`의 iOS CI와 C15의 관련 검사 5개는 통과했다. 같은 head의 [Core CI 34418552204](https://github.com/L3J-Vispace/Vispace/actions/runs/34418552204)는 계정 결제/사용 한도 문제로 실행 전에 차단됐다. C15 게시 커밋의 전체 CI는 PR의 head와 대조한다.

- 실기기·현장 검수와 Core CI 계정 차단이 남아 PR은 Draft로 유지한다. 후속 수정마다 해당 커밋의 검증 결과를 확인한다.
- 이번 수정본의 실기기 설치·실행 및 `DEVICE_ACCEPTANCE.md`의 실제 방, LiDAR/비 LiDAR, VoiceOver, 오차·열·메모리·배터리 측정. 11:23 KST 재조회에서 iPhone 16 Pro / iOS 26.6.1의 개발 서비스와 연결을 확인했다. 현재 남은 실행 전제는 Mac 서명 키 접근이다.
- 저널의 삭제 상태가 메타데이터에 아직 반영되지 않은 기록은 정리에서 삭제하지 않는다. 일반 복구로 정확한 상태를 먼저 반영해야 한다. 실제 디스크에 원자적 교체용 최소 공간조차 없으면 정리도 실패할 수 있다.
- 소스와 Simulator 통과를 현장 정확도·경로 안전성·배포 완료로 간주하지 않는다.

## 롤백

변경은 기능별 커밋으로 되돌린다. 저널 스키마 4로 저장한 데이터에 구형 앱을 바로 설치하지 않는다. 서비스 재검토 문서의 스키마/전송 형식 호환 조건을 유지하는 버전에서 기능만 되돌려야 한다.

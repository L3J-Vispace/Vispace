# 2026-09-05 구현·검증 결과

## 판정

1~6단계의 로컬 공간 처리 기능을 앱에 연결하고 자동 검증을 마쳤다.
**새 빌드의 실물 iPhone 설치와 현장 성능 검증은 완료하지 못했다.**
실기기 서명 중 `CodeSign: errSecInternalComponent`가 발생했으며,
원격 프로세스에서 로그인 키체인을 조회할 때도 `User interaction is not allowed`가 반환됐다.
인증서와 프로비저닝 프로파일은 선택됐지만 서명이 실패했으므로 설치를 진행하지 않았다.

## 확인한 항목

| 항목 | 결과 |
| --- | --- |
| VispaceCore | XCTest 262개 + Swift Testing 9개 통과 |
| iOS 통합 단위 테스트 | 283개 통과 |
| 화면 테스트 | 10개 통과 |
| 고유 자동 테스트 합계 | 564개, 실패 0개 |
| 검색창 대비 수정 후 해당 화면 재시험 | 통과; 위 합계에 중복 가산하지 않음 |
| Debug 시뮬레이터 빌드 | 통과, warnings-as-errors 활성화 |
| 최종 Release iOS 빌드 | 무서명 빌드 통과 |
| Xcode 정적 분석 | 통과 |
| Release 테스트 전용 실행 인수 | 카메라·권한·온보딩·검출기 모의 인수 7개가 바이너리에 없는지 확인 |
| 모델 | 배포 소스 SHA-256 일치, 컴파일된 모델 앱 내 포함 확인 |
| 서식·스크립트 | 변경 Swift strict format, shell syntax, git diff --check 통과 |

자동 테스트는 삭제 중 여러 세대의 취소된 작업을 모두 기다리는지,
늦게 끝난 이전 요청을 폐기하는지, 저장·복구의 일관성, 관계 최신성,
좌표·추적·바닥 근거 없는 안내 차단, 수치 오버플로 거부를 포함한다.
화면 테스트는 첫 실행 완료 후 재실행, 한국어 큰 글자, 권한 거부,
카메라 실패·불가, 검출기 불가, 검색·관계·배치의 정보 부족 처리,
데이터 설정과 삭제를 포함한다. 시뮬레이터 검증을 실물 공간 정확도로 해석하지 않는다.

최종 UI의 유일한 추가 변경은 카메라 밝기에 따라 검색창 글자가 흐려지지
않도록 입력창 배경을 시스템 배경색으로 고정한 것이다. 해당 화면 테스트와
Release 빌드를 이 변경 뒤 다시 통과시켰다.

## 실행 환경과 증거

- Mac: Xcode 26.6 (17F113), iOS SDK 26.5.
- 자동 테스트: iPhone 17 Pro 시뮬레이터.
- 연결 확인: iPhone 16 Pro, iOS 26.6.1, paired, Developer Mode enabled.
- 로컬과 Mac의 소스·테스트·리소스 해시를 비교했으며, 생성 프로젝트 차이를
  로컬 기준으로 동기화한 후 전체 iOS 테스트와 분석을 재실행했다.
- 로그: `TestResults/Final-2026-09-05/core.log`, `app-ui-analyze.log`,
  `contrast-ui.log`, `release.log`, `signing.log`.
- 화면 증거: 같은 폴더의 `camera-search.png`, `camera-recovery-ko-AXXXL.png`.
- 모델 SHA-256: `cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e`.

로그와 화면 증거는 개발 산출물로 `.gitignore` 대상이다. 이 문서는 이 날짜의
변경본에 대한 결과이며, 앞으로 수정된 코드의 통과를 보장하지 않는다.

## 다음 실행

Mac 데스크톱의 Terminal에서 이 프로젝트 디렉터리로 이동한 뒤 실행한다.
macOS가 서명키 사용 승인을 요청하면 사용자가 직접 처리한다. 스크립트는
키체인 정책을 바꾸거나 서명을 생략하지 않는다.

```bash
xcrun devicectl list devices
bash Scripts/install-device.sh DEVICE_UUID
```

이 스크립트의 구문·도움말은 검증했지만, 성공적인 실기기 설치 실행은 아직
검증하지 않았다. 설치 후에는 [실기기 검수표](DEVICE_ACCEPTANCE.md)를 순서대로
실행해 정상 결과와 정보 부족 처리를 구분해서 기록해야 한다.

아직 완료로 판정하지 않은 항목은 실제 방의 인식·중복 ID·재인식 오차,
가구 충돌·통로 판단, 경로 안전성, 장시간 발열·메모리, 비LiDAR 기기 검증,
서명된 아카이브·TestFlight·App Store 배포 및 clean-checkout 재검증이다.
클라우드 계정·동기화와 취향·스타일에 대한 자유 대화형 AI 추천은 현재
로컬·기하 기반 구현에 포함하지 않는다. 전체 출시 기준은
[단계별 구현 계획](IMPLEMENTATION_PLAN.md)에 남겨 두었다.

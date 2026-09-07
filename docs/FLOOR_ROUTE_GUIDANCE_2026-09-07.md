# 바닥 경로 안내 구현 및 검증 상태 — 2026-09-07

## 구현

참고 이미지의 바닥을 따라 이어지는 안내 표현을 기존의 검증된 실내 경로에 적용했다.

- 가느다란 막대와 구 대신 최대 폭 36cm의 반투명 청록색 리본, 안쪽 흰색 경계선, 75cm 간격 방향 표시와 도착 원을 렌더링한다.
- 원래 경로의 인접 구간과 관측 높이를 그대로 사용한다. 코너를 곡선으로 지름길 처리하지 않으며, 회전부 폭이 벽 쪽으로 돌출되지 않는다.
- 커스텀 경로 정책도 엔진의 `agentRadius`를 표시 폭 상한으로 전달한다. 경계선·방향 표시·도착 원도 이 상한 안에 제한한다.
- 길이에 관계없이 한 앵커와 최대 네 개의 메시로 묶는다. 근거 만료·추적 제한·지도/표면 변경·취소 시 기존 리본을 즉시 제거한다.
- 기존 재구성 메시의 occlusion을 활성화하여 관측된 가구와 벽 뒤에서는 AR 콘텐츠가 가려지게 했다.
- 확정된 검색 결과에 **이 위치까지 길 안내** 버튼을 추가했다. 선택된 물체 ID와 지도 ID를 유지하고 최신 기록·위치·신뢰도·좌표 정합을 다시 검증한다. 이름으로 다시 검색하여 다른 물체를 고르지 않는다.
- `키보드 어디있어?`로 검색한 뒤 버튼을 누르거나, 기존의 `키보드로 안내해줘` 요청을 사용할 수 있다. 바닥과 통로 근거가 부족한 경우에는 기존 부족 안내를 유지한다.

하단 지도나 새로운 지도 공급자는 추가하지 않았다. 이 변경은 표시 방식과 검색에서 길 안내로 넘어가는 연결을 다룬다.

## 확인된 결과

| 검사 | 결과 |
| --- | --- |
| 프로젝트 재생성 일치, 모델·개인정보 검사 | 통과 |
| iOS 17 배포 대상으로 Debug Simulator 앱/테스트 컴파일 | 통과 |
| 전체 Simulator 실행 (`651dae6`) | 566 통과, 1 실패, 2 실기기 전용 건너뜀 |
| 새 리본 기하 테스트 12개 | 통과 |
| 엔진의 커스텀 안전 폭 전달 테스트 1개 | 통과 |
| 선택된 물체의 길 안내 전환 테스트 5개 | 통과 |
| RealityKit 메시 배치·교체·즉시 제거·폭 검증 3개 | 통과 |
| 기존 UI 테스트 13개 | 통과 |
| 서명된 Release iPhone archive (`52a82f5`) | 생성 및 `codesign --verify --deep --strict` 통과 |
| 새 빌드의 iPhone 렌더링 테스트 | 4개 통과 (`ribbon-device2/Tests.xcresult`) |
| 새 빌드의 iPhone 설치 | Release 앱 설치 성공, 기기 앱 목록에서 `com.l3j.vispace` 재확인 |
| 설치된 앱의 일반 실행 | 최초 보안 사전 검사 거부 후, 재시도에서 기기 잠금 오류 확인. 잠금 해제 후 실행 확인 대기 |

실패한 검사는 `ARNavigationRibbonRenderingTests.testCaptureProductionRibbonOnLightAndDarkSyntheticFloors` 하나다. 두 색상 반복에서 `ARView.snapshot`이 경로와 바닥 전체를 검정색으로 반환하여 청록색 픽셀 단언에 실패했다. 합성 장면이라는 UIKit 설명만 보이므로 이 이미지는 시각 검증의 근거로 사용할 수 없다.

동일 시점 Metal 로그에 `meshShadowCasterProgrammableBlending`의 `reading from a rendertarget is not supported` 오류가 있었다. 테스트 장면에서 grounding shadows를 끄고 단독 실행했지만 해결되지 않았다. 기존 key window의 root controller를 교체하는 실험도 해결하지 못했다. 앱, UIWindowScene, 카메라는 활성 상태였다. 따라서 특정 shader 오류가 단일 원인이라고 확정하지 않는다.

Release Simulator 빌드와 정적 분석은 테스트 실패로 후속 스크립트가 중지되어 이 변경에 대해 아직 완료하지 못했다. 이전 물체 인식 작업의 성공 결과를 이번 변경의 완료 증거로 계산하지 않는다. 실제 방의 연속 보행·가림·위치 정합도 아직 확인되지 않았다.

## 재개 지점

Mac의 Tailscale 주소로 향하는 Windows SSH/TCP 22 연결은 `Permission denied` / socket access denied로 거부되었다. 같은 LAN 주소에서는 기존 SSH 키와 저장된 호스트키를 엄격하게 확인하여 동일한 Mac에 연결했다. VPN·방화벽·인증 정책은 변경하지 않았다.

- Mac checkout: `/Users/dlfkd/VispaceValidation/recognition-20260907`.
- 전체 실행: `TestResults/ribbon-check2/Tests.xcresult`.
- 그림자 옵션을 끈 단독 재실행: `TestResults/ribbon-render-recheck/Tests.xcresult`.
- key-window 실험: `TestResults/ribbon-fixture-window/Tests.xcresult`.
- 준비된 서명 빌드: `TestResults/ribbon-device2/Vispace.xcarchive`.
- iPhone 테스트/설치 스크립트 `TestResults/ribbon-device2`는 잠금 해제 후 렌더링 테스트 4개를 통과했고, 2026-09-07 23:10 KST Release 앱 설치에 성공했다. 일반 실행은 `Application failed preflight checks`로 거부되어 스크립트 전체 종료 코드는 1이다. 테스트 성공 및 설치 성공과 전체 스크립트 종료 코드를 구분한다.
- `TestResults/ribbon-install-now/installed-app.json`에서 설치를 재확인했다. 23:18 KST 일반 실행 재시도는 `Locked` / `FBSOpenApplicationErrorDomain` 오류 7로 거부되었다. 앱 실행과 실행 유지 확인은 아이폰 잠금 해제 뒤에 남아 있다.
- Mac의 `VispaceTests/ARNavigationRibbonRenderingTests.swift`만 key-window 실험으로 수정된 상태다. 연결 복구 후 해당 테스트 파일만 복원하거나 검토한 실험본으로 교체한 다음 공식 동기화를 수행해야 한다. 다른 파일을 일괄 초기화하지 않는다.
- Windows의 미검증 후속 실험은 gitignored `TestResults/MacRecognition-20260907/ribbon-fixture-warm.swift`와 `ribbon-fixture-experiment.sh`에 보존했다. 앵커·투영 좌표와 픽셀 준비 상태를 제한 시간 안에 기록하고, 같은 시점의 `simctl` 화면과 비교하여 실제 표시와 snapshot API 문제를 구분한다. 이 실험은 아직 실행하지 못했다.

최종 시각 승인과 설치된 앱의 일반 실행 확인이 남아 있다. 실기기 합성 캡처 테스트의 통과는 실제 방에서 보행한 경로의 정확도 검증을 대신하지 않는다. 검정 Simulator 캡처를 승인된 미리보기로 배포하거나, 테스트 건너뜀/단언 완화로 통과한 것처럼 처리하지 않는다. 개인 사진, 캡처, 서명 파일 및 진단 자료는 Git에 포함하지 않았다.

참조한 API 문서: [RealityKit MeshDescriptor](https://developer.apple.com/documentation/realitykit/meshdescriptor), [UnlitMaterial](https://developer.apple.com/documentation/realitykit/unlitmaterial), [scene occlusion](https://developer.apple.com/documentation/realitykit/arview/environment-swift.struct/sceneunderstanding-swift.struct/options-swift.struct/occlusion).

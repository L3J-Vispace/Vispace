# 시간 기록·재식별·자원 제한 보완

## 적용한 변경

- **A03:** journal에서 처음 복구할 때 물체 metadata가 이미 같아도 전체 metadata writer를 다시 호출한다. 물체 저장 직후 프로세스가 끝나 관계 저장이 누락된 경우에도 관계 projection을 재실행한다. 같은 actor의 복구 완료 캐시는 매번 다시 쓰지 않는다.
- **A04:** `TemporalSpatialMemoryService.reset()`이 coordinator와 projection 대기 상태를 비우며, 이전 generation의 비동기 복구 결과를 거절한다. 호출자는 인식 작업을 중단하고 모든 저장 작업이 끝난 것을 기다린 다음 reset과 영구 저장소 삭제를 수행해야 한다.
- **B05:** 공간 물체 한도에 도달하면 새로운 ID만 보류한다. 기존 물체의 관측·미관측 증거와 journal revision은 계속 갱신한다. 남은 슬롯은 ObjectID 정렬 순서로 배정하여 replay가 같은 결과를 낸다. 보류 ID를 인식 pipeline의 저장 완료 캐시에 넣지 않는다. 일반 랜드마크가 Re-ID 후보 개수 한도를 소모하지 않도록 실제 후보만 resolver에 전달한다.
- **B11:** 저전력 모드에서는 인식 작업 시작 간격을 0.5초, thermal serious에서는 1초 이상으로 제한한다. critical에서는 pipeline과 대기 프레임을 해제하고 인식을 일시 중단한다. 온도가 회복되면 새 관측으로 자동 재개한다. 이 값은 자원 제한 정책이며 실기기에서 측정한 처리율·배터리 성능 수치가 아니다.
- 저장 실패 메시지는 단순 scanning 상태 전환으로 사라지지 않으며, 다음 저장 성공 또는 전체 삭제 뒤 명시적 초기화로 해제한다. 실제 저장 실패와 복원 실패는 각각 유지한다.

## A05: 달력 시간과 처리 순서 분리

`capturedAt`, `firstSeenAt`, `lastSeenAt`, `stateUpdatedAt`은 실제 관측 당시의 달력 시간을 보존한다. 기기 시간이 정상으로 돌아오면 `lastSeenAt < firstSeenAt`이 될 수 있으며, 날짜를 미래로 올리거나 과거 기록을 다시 쓰지 않는다. v2 물체의 양의 `temporalRevision`이 저장 순서를 결정하므로, 실제 날짜가 이전 값보다 작아도 최신 관측을 저장할 수 있다. 같은 revision의 다른 관측이나 이전 revision은 저장소와 delta reducer에서 거절한다.

각 capture segment는 영구 journal의 clock epoch에 연결된다. 같은 epoch 안에서는 AR 세션의 단조 증가 시간이 엄격히 증가해야 한다. 새 segment는 다음 epoch를 사용하고, 재시작 뒤에도 이전 segment의 재유입을 거절한다. 미관측 유예와 이동 증거 간격은 달력 시간이 아닌 세션 경과 시간으로 계산한다. epoch 전환이나 달력 역행 시 기존 미관측·이동 증거를 초기화하고 새 증거부터 보수적으로 누적한다. 인식 pipeline도 달력 역행 시 진행 중 promotion 창을 초기화한다.

metadata 문서, temporal journal catalog, snapshot은 명시적으로 schema v2를 기록하며 v1을 읽어 마이그레이션한다. schema probe는 해당 저장소에서만 v2를 허용하므로 구버전 앱의 미래 schema 보존 처리와 호환된다. journal이 없는 가져온 공간은 객체의 최대 temporal revision을 시작점으로 사용하고, 기존 날짜와 사용자 이름을 보존한 채 관계 projection을 복구한다. 첫 새 관측은 이 revision보다 큰 값을 사용한다.

관계는 endpoint의 temporal revision과 실제 생성 날짜를 함께 기록한다. 저장된 graph의 미래 날짜 high-water mark를 새 관계 날짜로 사용하지 않는다. 아직 미래 날짜인 물체의 관계는 보류·제거하고 cold recovery 자체는 정상 완료한다. 해당 물체를 현재 시간에 재관측하면 새 revision으로 관계를 다시 생성한다. metadata 저장과 관계 저장 사이의 조회는 endpoint revision 불일치로 오래된 관계를 거절한다.

과거 관측 당시 기기 시계가 정확했는지는 이 변경만으로 복원할 수 없다. 원래 날짜를 그대로 보존하므로 과거 기록의 절대 날짜는 기기 설정의 영향을 받는다. 재유입 차단용 retired segment ID는 공간당 최대 4,096개를 보존하며, 이 한도를 넘는 새 epoch는 기록을 조용히 버리는 대신 명시적 오류로 중단한다. 이 한계와 실제 iPhone의 시계 변경·앱 재실행 동작은 기기 검증 항목에 포함한다.

## B08: 멀리 이동한 물체의 동일성은 미확정

현재 Re-ID는 같은 map/frame에서 0.75m 이내 위치·크기와 높은 공간 문맥 점수를 사용한다. 이전 위치에서 멀리 떨어진 같은 종류 물체가 동일 개체인지 새 개체인지 이 증거만으로는 결정할 수 없다. 거리 문턱을 넓히거나 이름·색상만으로 ID를 재사용하면 서로 다른 의자 등이 합쳐질 수 있으므로 그렇게 수정하지 않았다. 기존의 먼 물체/removed 물체를 자동 병합하지 않는 회귀 검사를 유지한다.

장거리 이동 이력을 연결하려면 이동 전후의 검증된 시각 특징, 관측 중 끊김 없는 3D 추적, 혹은 명시적 사용자 확인을 위한 별도 증거가 필요하다. 현재 앱의 실제 appearance 모델·평가 자료 없이 해당 기능이 완성되었다고 주장하지 않는다.

## 검증 범위

회귀 검사는 동일 metadata 이후 writer 재실행, reset 중 비동기 복구 무효화, 용량 제한 중 기존 기록 갱신과 보류 재시도, legacy 미래 날짜의 첫 갱신, 달력 점프 중 단조 시간 기반 부재 판단, 재시작 뒤 retired epoch 거절, v1 snapshot migration, 높은 revision을 가진 공간 가져오기, 실제 시간으로 관계 재생성과 stale projection 차단, 저전력/발열별 처리 간격 및 critical 이후 복귀를 다룬다. 실제 실행 결과와 iPhone 실기기 측정 결과는 상위 검증 보고서에서 별도로 확인한다.

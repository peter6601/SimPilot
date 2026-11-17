# SimPilot

iOS 模擬器自動化的個人工具：讀畫面元素（label、role、frame）、用 label 點擊。輸出 JSON，`/duo-verify` 的 `duo_check.py` 可以直接讀。

## 怎麼運作

```
simpilot (CLI) ──Unix socket──▶ SimPilot.app（選單列，持有 daemon）
                                   │ 需要時用 xcodebuild test-without-building 起 runner
                                   ▼
                     模擬器裡的常駐 XCUITest server（Runner/）──HTTP 127.0.0.1──
                     用 XCUIApplication(bundleIdentifier:) 附掛已在跑的 app，不呼叫 launch()
```

- runner 第一次啟動約 15 秒，之後每次 `elements` 0.3–0.6 秒、`tap` 約 2 秒。
- runner 跑著時 xcodebuild 一直在執行，`safe-xcodebuild.sh` 會擋掉其他 build；所以閒置超過設定時間（預設 3 分鐘，選單列可改）就自動關掉。要馬上 build 別的東西：`simpilot stop`。
- runner 自己也有看門狗（閒置時間＋60 秒），daemon 被強制結束時不會一直佔著 xcodebuild。
- xcodebuild 一律經過 `~/.claude/skills/duo-verify/scripts/safe-xcodebuild.sh`（沒有這支就直接用 `xcrun xcodebuild`，或用 `SIMPILOT_XCODEBUILD` 指定）。別人的 xcodebuild 在跑時回 `xcodebuild_busy`，附上對方的 PID 和指令，不重試。

## 安裝與使用

```sh
scripts/make-app.sh          # 產生 build/SimPilot.app 和 build/simpilot
build/simpilot runner build  # 第一次、或改了 Runner/ 之後（需要 xcodegen）

build/simpilot elements --udid <UDID> > out.json
build/simpilot interact tap --label 設定 --udid <UDID>
build/simpilot status
build/simpilot stop

build/simpilot duo pose book --udid <UDID>   # closed | book | open
build/simpilot duo hinge --udid <UDID>
```

- CLI 找不到 daemon 會自己開 `build/SimPilot.app`（或 `/Applications/SimPilot.app`）；兩個都沒有就在背景起 `simpilot daemon`。
- 沒給 `--bundle` 時，從模擬器上正在跑的 app 裡挑在前景的那個。
- 輸出：`{"ok": true, "data": {"canvasSize": [w, h], "elements": [...]}}`，元素有 `id`、`label`、`role`、`frame`、`stableKey`、`identifier`、`parentId`、`value`。canvasSize 和 frame 是目前介面方向的 pt 座標。
- tap 回 `data.tapped`、`data.screen_changed`、`data.appeared`、`data.disappeared`、`data.moved`（兩邊都有、但位置變了的 label，例如兩張卡片對調位置；打開 sheet 時，被蓋住的元素和 sheet 裡的同名元素也會算進來）、`data.value_changed`（value 變了的 label）。只點 hittable 的元素，button 優先。
- exit code：0 成功、1 失敗（`error` 欄位：`missing_udid`、`app_not_running`、`app_not_foreground`、`not_found`、`not_hittable`、`runner_not_built`、`xcodebuild_busy`、`runner_exited`、`runner_timeout`）。

## Duo 姿態（`duo pose`／`duo hinge`）

- `duo pose` 點 Device Hub 視窗上的 Closed／Partially Open／Open，切完用 `devicectl device info displays` 確認亮的是哪一面（closed 要亮外螢幕，book／open 要亮內螢幕），對不上就重點，最多 3 次。book 會先切 Open 再切 Partially Open，因為從 Closed 直接掀到半開會一直停在外螢幕。
- 需要：Device Hub 開著、選在這台模擬器上（不是就回 `devicehub_wrong_device`，不會點到別台），跑 simpilot 的終端機或 app 要有「輔助使用」權限。這兩個指令直接在 CLI 執行，不經 daemon。
- `duo hinge` 回 `hinge_state`（`closed`／`partiallyOpen`／`openFlat`）、`active_display`、`display_orientation`。**角度一律是 null，狀態是推斷的**：亮外螢幕就是 closed；亮內螢幕時，book 和 open 靠 SimPilot 上次設的姿態來分，分不出來回 `unknown`。`source` 欄位會寫出依據。
- 讀不到真正角度的原因：`devicectl` 沒有 hinge 指令；`UIHingeInteraction` 只在前景 app 收得到更新（runner 在背景，實測 0 筆）；Device Hub 畫面上不顯示角度。CoreDevice 私有框架裡有讀角度的 action，要逆向 Swift 私有 API 才能用，還沒做。

## 限制

- 不列被 fullScreenCover／sheet 蓋住的下層元素，所以元素數比較少；`--baseline` 照樣可用。
- `duo pose` 只有三個固定姿態（Device Hub 的按鈕），`duo hinge` 沒有角度；還沒有 `screenshot` 和 `interact` 的其他動作。

## 檔案

- `Sources/SimPilotCore`：Unix socket、daemon、runner 生命週期
- `Sources/simpilot`：CLI
- `Sources/SimPilotMenuBar`：選單列 app
- `Runner/`：模擬器裡的 XCUITest server（xcodegen 專案）
- `spikes/`：技術驗證時的三條路原型
- 記錄檔：`~/Library/Logs/SimPilot/`；socket 與 runner build：`~/Library/Application Support/SimPilot/`

# SimPilot

**中文** | [English](README.en.md)

iOS 模擬器自動化的 CLI 加選單列 app。

相關：[duo-verify-skill](https://github.com/peter6601/duo-verify-skill)：用 SimPilot 在 iPhone Duo 上自動驗畫面的 Claude Code skill。

簡報：[常駐副駕](https://ios-dev-skill-deck.vercel.app/simpilot/)：一次看懂 SimPilot 為什麼做、怎麼運作、在 Duo 上怎麼用。

- 讀畫面上的元素：label、role、frame。
- 用 label 點按鈕。
- 切 iPhone Duo 的姿態，讀回目前姿態。
- 輸出 JSON，[duo-verify](https://github.com/peter6601/duo-verify-skill) 的 `duo_check.py` 可以直接讀。

## 為什麼做這個

目的：讓 AI agent（例如 Claude Code）在終端機裡自己操作模擬器、驗證畫面。

它解決的問題：

- agent 要判斷版面，需要每個按鈕的座標，光看截圖不夠精確。
- Xcode 內建的 UI 快照沒有座標。
- 現成的 accessibility 工具在 Xcode 27.2 跑不起來。
- 一般的 XCUITest 會重啟 app，走到一半的畫面和狀態會不見。
- 每次都起一次 XCUITest 太慢，一次要十幾秒。

SimPilot 的做法：

- 附掛在已經開著的 app 上，不重啟，畫面停在哪就讀哪。
- runner 常駐，之後每次讀元素不到 1 秒。
- 用 label 點擊，回報畫面有沒有變、哪些元素出現、消失、換位置。
- 沒有次數限制，可以反覆跑同一套檢查。
- 全部在本機，指令輸出 JSON，方便 agent 和腳本讀。

## 在 iPhone Duo 上的幫助

iPhone Duo 是折疊機：有外螢幕、內螢幕，還有折痕。同一個畫面要在多種姿態和方向下都正常。

手動測的麻煩：

- 一個畫面要測 9 種組合：半折、攤開各 4 個方向，加上闔起 1 格。
- Device Hub 的姿態按鈕偶爾會吞掉點擊，切了不一定到位。
- 轉軸有遲滯：同一個角度，亮的可能是外螢幕也可能是內螢幕。
- 按鈕壓到狀態列、home indicator 或折痕，肉眼不容易看出來。

SimPilot 幫你做到：

- `duo pose` 從終端機切到 closed、book、open，切完確認亮的是哪一面，沒到位就重點。
- `duo hinge` 讀回目前姿態、亮的是哪一面、畫面方向。
- `elements` 的座標跟著目前的螢幕和方向走，可以直接算按鈕有沒有壓到折痕或系統區域。
- 搭配 [duo-verify](https://github.com/peter6601/duo-verify-skill)，agent 可以自己跑完 9 格矩陣，交出每一格的問題清單。

## 怎麼運作

```
simpilot (CLI) ──Unix socket──▶ SimPilot.app（選單列，持有 daemon）
                                   │ 需要時用 xcodebuild test-without-building 起 runner
                                   ▼
                     模擬器裡的常駐 XCUITest server（Runner/）──HTTP 127.0.0.1──
                     用 XCUIApplication(bundleIdentifier:) 附掛已在跑的 app，不呼叫 launch()
```

- runner 附掛在正在跑的 app 上，不會重啟它。
- 第一次啟動 runner 約 15 秒。
- 之後 `elements` 約 0.3–0.6 秒，`tap` 約 2 秒。
- runner 跑著時會佔住 xcodebuild。
- 閒置 3 分鐘自動關掉（選單列可改）。
- 要馬上 build 別的東西，先跑 `simpilot stop`。
- daemon 被強制結束時，runner 會在閒置時間＋60 秒後自己關。

## 需求

- macOS 14 以上。
- Xcode，含 iOS 17 以上的模擬器 runtime。
- 實測環境：Xcode 27.2、iOS 27.2。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`。
- `duo pose` 另外需要「輔助使用」權限，見下方。

## 安裝

```sh
git clone https://github.com/peter6601/SimPilot.git
cd SimPilot
scripts/make-app.sh                  # 產生 build/SimPilot.app 和 build/simpilot
build/simpilot runner build          # 編模擬器裡的 runner
ln -s "$PWD/build/simpilot" /usr/local/bin/simpilot   # 選用：放進 PATH
```

- clone 下來的資料夾要留著，CLI 從這裡找 app 和 runner。
- 所以用 symlink 放進 PATH，不要複製執行檔。
- PATH 目錄依你的設定，例如 `~/bin`、`~/.local/bin`。
- `build/SimPilot.app` 也可以拖進 `/Applications`。
- 改了 `Runner/` 之後，要再跑一次 `simpilot runner build`。

解除安裝：

1. 跑 `simpilot stop`。
2. 刪掉 clone 的資料夾和 PATH 裡的 symlink。
3. 刪掉 `~/Library/Application Support/SimPilot/` 和 `~/Library/Logs/SimPilot/`。

## 使用

- 先開模擬器，把要測的 app 打開。
- SimPilot 不會幫你啟動 app。
- UDID 用 `xcrun simctl list devices booted` 查。

```sh
simpilot elements --udid <UDID> > out.json          # 讀元素
simpilot interact tap --label 設定 --udid <UDID>     # 用 label 點擊
simpilot status                                      # 看有哪些 runner 在跑
simpilot stop                                        # 關掉 runner，讓出 xcodebuild

# 只有 iPhone Duo 模擬器
simpilot duo pose book --udid <UDID>                 # closed | book | open
simpilot duo hinge --udid <UDID>
```

- 第一次跑 CLI 會在背景開 SimPilot.app，選單列多一個圖示。
- 選單列可以看 runner 狀態、關掉 runner、改閒置時間。
- 找不到 app 時，CLI 會在背景起 `simpilot daemon` 代替。
- 沒給 `--bundle` 時，自動挑模擬器前景的 app。

`duo pose` 的準備：

1. 在 Xcode 開 Device Hub，選到這台 Duo 模擬器。
2. 系統設定 → 隱私權與安全性 → 輔助使用，打開你用的終端機。

## 輸出

`elements`：

- 格式：`{"ok": true, "data": {"canvasSize": [w, h], "elements": [...]}}`。
- 每個元素有 `id`、`label`、`role`、`frame`、`stableKey`、`identifier`、`parentId`、`value`。
- canvasSize 和 frame 是目前介面方向的 pt 座標。
- 只列看得到的元素，被 sheet、fullScreenCover 蓋住的不列。

`interact tap`：

- 只點 hittable 的元素，同名時 button 優先。
- `tapped`：點了哪個元素。
- `screen_changed`：畫面有沒有變。
- `appeared`／`disappeared`：多了、少了哪些 label。
- `moved`：位置變了的 label，例如兩張卡片對調。
- `value_changed`：value 變了的 label。

錯誤：

- exit code 0 成功，1 失敗。
- 失敗時看 `error` 欄位。
- 常見的有 `app_not_running`、`app_not_foreground`、`not_found`、`not_hittable`。
- runner 相關：`runner_not_built`、`runner_exited`、`runner_timeout`。
- `xcodebuild_busy`：別人的 xcodebuild 在跑，會附上對方的 PID 和指令。

## Duo 姿態

`duo pose`：

- 點 Device Hub 上的 Closed／Partially Open／Open。
- 只有這三個固定姿態，不能設任意角度。
- 切完用 `devicectl` 確認亮的是哪一面。
- closed 要亮外螢幕，book、open 要亮內螢幕。
- 對不上就重點，最多 3 次。
- book 會先切 Open 再切半開：從 Closed 直接半開，會一直停在外螢幕。
- Device Hub 選的不是這台模擬器時，回 `devicehub_wrong_device`，不會點到別台。
- 這兩個指令直接在 CLI 執行，不經 daemon。

`duo hinge`：

- 回 `hinge_state`、`active_display`、`display_orientation`。
- `hinge_state` 是 `closed`／`partiallyOpen`／`openFlat`。
- **角度一律是 null。**
- **狀態是推斷的**：
  - 亮外螢幕就是 closed。
  - 亮內螢幕時，靠 SimPilot 上次設的姿態分 book 和 open。
  - 分不出來回 `unknown`。
- `source` 欄位寫出推斷依據。

為什麼讀不到角度：

- `devicectl` 沒有 hinge 指令。
- `UIHingeInteraction` 只有前景 app 收得到，runner 在背景。
- Device Hub 畫面不顯示角度。
- CoreDevice 私有框架有讀角度的功能，要逆向才能用，還沒做。

## 還沒有的功能

- 截圖：先用 `xcrun simctl io <UDID> screenshot`。
- 點擊以外的操作：滑動、打字、長按。

## xcodebuild

- 預設經過 `~/.claude/skills/duo-verify/scripts/safe-xcodebuild.sh`。
- 這支腳本在別人的 xcodebuild 跑著時會擋下來。
- 沒有這支就用 `xcrun xcodebuild`。
- 要換別的包裝腳本，設 `SIMPILOT_XCODEBUILD`。

## 檔案

- `Sources/SimPilotCore`：Unix socket、daemon、runner 生命週期。
- `Sources/simpilot`：CLI。
- `Sources/SimPilotMenuBar`：選單列 app。
- `Runner/`：模擬器裡的 XCUITest server（XcodeGen 專案）。
- `spikes/`：技術驗證時的原型，不在主程式裡。
  - `ax-bridge`、`simapp-ax` 用了 Apple 私有框架，只作研究紀錄。
- 記錄檔：`~/Library/Logs/SimPilot/`。
- socket 和 runner build：`~/Library/Application Support/SimPilot/`。

## 授權

MIT，見 [LICENSE](LICENSE)。

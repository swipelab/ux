### 0.18.0
- **A camera page showing an error leaves the picker's camera cell in view.**
  A `CameraPage` covers its picker's camera cell only while it flies the
  cell's preview, so the cell shows under a camera page with an error, as
  after a failed capture, through its exit and on the frame it leaves.
- **A video's preview player lives while any compose shows it.**
  `ComposeEntry.retainVideo` holds an entry's preview player, loading it for
  the first hold, and `ComposeEntry.releaseVideo` drops a hold, disposing the
  player with the last. Each `ComposePage` holds the player of the video it
  shows, so a compose reopened on a video while an earlier compose on it
  leaves keeps its player after the earlier one is disposed. Breaking:
  `ComposeEntry.disposeVideo` is replaced by `ComposeEntry.releaseVideo`.
- **A picker's compose entries live until the last screen showing them
  leaves.** `ComposeEntry.retain` adds a hold on an entry and
  `ComposeEntry.release` drops one, disposing the entry with the last.
  `MediaPickerPage` and each `ComposePage.borrowed` hold the entries they
  share, so a compose page popped with its picker in one event, as on
  sign-out, paints its entries through its exit.
- **A leaving screen takes no taps.** A screen leaving a `ScreenStack` takes
  no pointer through its pop animation, so a tap on a dismissed screen's
  button reaches the screen under it. A screen takes taps as it enters and
  while a back gesture drives it or springs it back.
- **A screen with no pop animation leaves at once.** A screen leaving a
  `ScreenStack` with no pop animation to run, as with a zero
  `transitionDuration`, leaves in the build that drops it, so it builds and
  paints no frame after its pop. A leaving screen's `onRemoved`, and the
  stack's, run after the frame it leaves in.
- **A dotted IPv4 address is no phone number.** `XUrl.match` links a bare
  IPv4 address as `http://` and the address on every platform, whatever its
  digits: `ip 192.168.1.1 x` links `http://192.168.1.1`. A number dotted like
  an IPv4 address that a `0` starts, a national trunk prefix, is a phone
  number: `call 044.123.45.67 now` links `tel:0441234567`, and
  `ip 010.000.000.001 x` links `tel:010000000001`. On Android and Windows, an
  IPv4 address that Chinese, Japanese, Korean, Thai, Lao, Khmer or Myanmar
  letters follow links, as on iOS and macOS: `访问192.168.1.1然后` links
  `http://192.168.1.1`.
- **A web link's URL on iOS and macOS is the text it covers.** On iOS and
  macOS, `XUrl.match` gives a web link `NSDataDetector` finds the text it
  covers for its URL, after `http://` where it writes no scheme, as on Android
  and Windows, so its `%` escapes, its host's case and an IDN host's letters
  stay as written: `see https://WWW.例子.com/路径%20x y` links
  `https://WWW.例子.com/路径%20x`.
- **A bare IPv4 address, a port and a URL `NSDataDetector` misses link on iOS
  and macOS as on Android and Windows.** On iOS and macOS, `ip 10.0.0.1 x`
  links `http://10.0.0.1`. A bare domain's port that a letter outside Chinese,
  Japanese, Korean, Thai, Lao, Khmer or Myanmar follows stays out of its link:
  `访问example.com:8080abc然后` links `http://example.com`. A port those letters
  follow has ASCII digits: `访问example.com:8080٣然后` links
  `http://example.com`. A URL with a scheme that `NSDataDetector` misses links
  as `Patterns.WEB_URL` matches it where a `_` that begins a word or follows
  those letters comes before its scheme: `foo _http://example.com:8080abc x`
  links `http://example.com`.
- **A `ScreenHero` flies.** A `ScreenHero` registers with the `ScreenStack`
  around it. When a screen is pushed over another or popped off it, a hero on
  one that shares its tag with a hero on the other flies from its place to the
  other's over the transition, in the `Overlay` around the stack; a pop that a
  back gesture drives does not fly, and a flight lands as either screen hides.
  `ScreenHeroController` takes a hero's state in `register` and `unregister`,
  flies heroes between two slots with `fly` and lands the flights from or to a
  slot with `land`, and `ScreenSlot.maybeOf` finds the slot whose screen holds
  a context. Breaking: `ScreenHeroController.register` and `unregister` take
  the hero's state alone, and `ScreenHeroController.snapshot`,
  `ScreenHeroController.maybeStartFlights` and `ScreenHeroState.globalRect`
  are removed.
- **macOS and Windows report Reduce Motion.** `XAccessibility.reduceMotion`
  (`package:ux/accessibility.dart`) holds whether the OS asks apps to reduce
  motion where Flutter's embedder does not report it, and follows its changes
  while the app runs: on macOS the Reduce motion setting, `NSWorkspace`'s
  `accessibilityDisplayShouldReduceMotion`, read again on each
  `accessibilityDisplayOptionsDidChangeNotification`, and on Windows Animation
  effects off, `SPI_GETCLIENTAREAANIMATION`, read again on each
  `WM_SETTINGCHANGE`. On iOS, Android and Linux, whose Flutter
  `AccessibilityFeatures` carry the setting, it stays false.
- **A bare domain links on iOS and macOS as on Android and Windows.** On iOS
  and macOS, `XUrl.match` links a web match with no scheme only where its host
  is an IP address or ends in a top-level domain on IANA's list, as on Android
  and Windows, so `see www.example.com.Then you` and
  `see example.com.Then/x you` link nothing. A bare domain on a top-level
  domain `NSDataDetector` does not know links with no path after it, and
  straight after Chinese, Japanese, Korean, Thai, Lao, Khmer or Myanmar
  letters: `banlu.app` links `http://banlu.app` and `访问banlu.app/x` links
  `http://banlu.app/x`. A bare domain straight after Lao, Khmer or Myanmar
  letters links on any top-level domain: `មើលexample.com` links
  `http://example.com`.
- **A web link leaves out the quotes and brackets around it.**
  `XUrl.match` ends a web link before a trailing `'` or `(`, and before a `"`,
  `<`, `>`, `[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}` or a `%` that two hex
  digits do not follow, which `Patterns.WEB_URL`'s path does not take; an IP
  literal host keeps its brackets. `He said 'https://example.com/a'.` and
  `see <https://example.com/a> x` link `https://example.com/a` on every
  platform. On iOS and macOS, `see "example.com/a" x` links
  `http://example.com/a`, `see example.com/a|example.org/b z` links
  `http://example.com/a` and `http://example.org/b`, and
  `[see https://en.wikipedia.org/wiki/Foo_(bar)] x` links
  `https://en.wikipedia.org/wiki/Foo_(bar)`, as on Android and Windows.
- **A link written with non-ASCII text opens before iOS 17 and macOS 14.** On
  iOS and macOS, `XUrl.launch` percent-encodes a link's UTF-8 bytes outside RFC
  3986's URL characters, a `#` after the first and a `[` or `]` outside the
  authority before opening it, and keeps a `%` that two hex digits follow, so
  `https://zh.wikipedia.org/wiki/北京_(城市)` opens
  `https://zh.wikipedia.org/wiki/%E5%8C%97%E4%BA%AC_(%E5%9F%8E%E5%B8%82)` and
  `https://example.com/aé%20b` opens `https://example.com/a%C3%A9%20b`.
- **A web link leaves out a `)` it does not open.** On iOS and macOS,
  `XUrl.match` ends a web link `NSDataDetector` finds before a trailing `)` the
  link does not open and a trailing `.`, `,`, `;` or `!`, as on Android and
  Windows, so `(see https://example.com/a_(b)).` links
  `https://example.com/a_(b)`.
- **A video export cancelled as it starts ends cancelled.** On iOS and macOS,
  `XVideoExportSession.cancel` fails `done` with `cancelled` and leaves no file
  whenever it comes after `XVideoExporter.start`, right after it included, on
  the pass-through and the re-encoding path, as on Android and Windows.
- **Windows captures from cameras.** `uxAvailableCameras` lists Windows's
  video capture devices, each as the back lens with a `sensorOrientation` of 0,
  as macOS lists an external camera, and `XCameraController` previews, takes
  JPEG photos and records H.264/AAC MP4s on Windows through Media Foundation's
  capture engine, writing `ux_camera_<GUID>.jpg` and `.mp4` in the temporary
  directory. Flash and orientation locks succeed and change nothing. The
  permission checks answer whether Windows's Privacy & security settings let
  desktop apps use the camera and the microphone, and the requests answer the
  same, since Windows shows no prompt, first opening the camera's or the
  microphone's privacy page where it is denied; `openSystemSettings` opens the
  camera's privacy page. Where Media Foundation is missing,
  `uxAvailableCameras` throws `no_camera`.
- **Windows shares files.** `XFiles.share` on Windows opens the Windows share
  window over the app's window and hands it the file, titled with `title` or
  else the file's name. The window places itself, so `sourceRect` is ignored,
  as `mimeType` is; `share` answers false when the app has no window.
  `XFiles.supportsShare` is true on Windows.
- **Windows encrypts uploads natively.** `XCrypto.aesCtrEncryptRange` and
  `XCrypto.aesCtrBytes` on Windows run AES-256-CTR through CNG off the platform
  thread: AES in ECB mode, with AES-NI where the CPU has it, encrypts the
  counter blocks into the keystream XORed over the data, and
  `aesCtrEncryptRange` reads the file's range itself, so only ciphertext crosses
  the channel. `XCrypto.isSupported` is true on Windows.
- **The AES-CTR counter carries across all 128 bits on iOS and macOS.**
  `XCrypto.aesCtrEncryptRange` and `XCrypto.aesCtrBytes` on iOS and macOS
  carry the counter from its low 64 bits into its high 64 bits where they wrap,
  so their ciphertext equals `encryptChunk`'s for every `iv` and `pos`, as on
  Android and Windows.
- **A word a period glues to a bare domain makes it no link.** On Android and
  Windows, `XUrl.match` links a web match with no scheme only where its host is
  an IP address or ends in a top-level domain on IANA's list, in lowercase or as
  its Unicode label, or in com, edu, gov, net or org in any case.
  `see example.com.Then you`, `see example.com.It works` and
  `see example.com.Über x` link nothing, as on macOS. On iOS and macOS, Chinese
  or Japanese text before such a domain does not change this:
  `访问example.com.Then` and `访问example.com.Then/a` link nothing, as on
  Android and Windows.
- **A cancelled video export ends.** On iOS and macOS, cancelling an export
  that re-encodes with a `transform` while it runs fails `done` with
  `cancelled` and deletes the partial file, as on Android and Windows.
- **A video keeps its speed when it starts playing.** On iOS and macOS,
  `XVideoPlayerController.play` plays at the speed `setPlaybackSpeed` last
  set, a speed set while paused included, so the speed holds after a pause and
  when a looping video restarts, as on Android and Windows.
- **A video that already failed to load fails `initialize`.** On iOS and
  macOS, `XVideoPlayerController.initialize` and
  `XVideoPlayerBackend.initialize` fail at once with `decode_failed` and the
  load's error when the video failed to load before `initialize` was called,
  as when it fails while `initialize` waits.
- **A video that fails to load before `initialize` reports it on Windows.**
  On Windows, a player whose video fails to load before `initialize` emits an
  `XVideoPlayerError` with `playback_failed` and the load's error, and
  `initialize` then fails with `decode_failed`, as on iOS and macOS.
- **A video streams over http(s) on Windows.** On Windows,
  `XVideoPlayerController.network` and `XVideoPlayerBackend.create` take an
  http(s) URL, which Media Foundation's media engine streams, as on iOS, macOS
  and Android.
- **A second dispose of a video player is a no-op.**
  `MethodChannelXVideoPlayerBackend.disposeInstance` completes when the
  platform answers that the player is already disposed, as
  `XVideoPlayerBackend.disposeInstance` documents.
  `XVideoPlayerController.dispose` fails with any other error the platform
  answers, once it has disposed the controller.
- **A link's path past fullwidth parentheses is no second link.** On every
  platform, `XUrl.match` links no part of the path a web link runs on into
  past fullwidth parentheses, `（` and `）`, so
  `https://example.com/a（1）/page.com` links `https://example.com/a` alone,
  not also `http://page.com`. A domain past any other ideographic, fullwidth
  or halfwidth punctuation, or with no `/`, `?`, `#`, `&` or `=` between it and
  the mark before it, links on its own:
  `https://example.com/a，/example.org` and
  `https://example.com/a，备用:example.org` link `http://example.org`.
- **Windows pastes images and files.** `XClipboard.readFiles` on Windows
  answers the path and name of each file an Explorer copy put on the
  clipboard. `XClipboard.readImage` answers the bytes of the clipboard's
  `PNG` format, or a bitmap the clipboard holds as `CF_DIBV5` or `CF_DIB`,
  uncompressed at 1 to 32 bits a pixel, encoded as PNG, with alpha where a V4
  or V5 header has an alpha mask. `XClipboard.hasMedia` answers whether the
  clipboard holds any of these without reading them.
- **Windows takes dropped files.** `XDrop` on Windows reports a drag of files
  over the app's window, at Flutter's logical coordinates, and delivers the
  dropped files and folders, answering copy while a drop region is active and
  none otherwise. A file a source offers only as a virtual file, such as an
  Outlook attachment or an image from a browser, is written to
  `%TEMP%\ux_drops\<GUID>\<name>` and delivered with `isTemporaryCopy`.
  `XDrop.startZip` on Windows zips a dropped folder in an isolate into
  `<temp>\ux_drops\<uuid>\<folder>.zip`, deflated, with the folder as the
  archive's root and zip64 records past 4 GiB or 65,535 entries, reporting the
  fraction of bytes read; a cancel answers null and a failure throws, and
  either removes that directory.
- **Windows shows toasts.** `XNotifications` on Windows shows a toast under the
  process's explicit AppUserModelID, with the title and the body as its lines;
  a later toast with the same id and thread replaces it, `cancelByThread`
  removes a thread's toasts and `cancelAll` all of them. `requestPermission`
  answers whether toasts are enabled for the app and emits `authorization`. A
  click restores and raises the app's window and reaches `onTap` with the
  toast's data, through the COM class the host names with the new C API
  `XPluginCApiSetToastActivator`; a click after the app has exited starts it.
  Every method of a process with no AppUserModelID fails with
  `no_app_user_model_id`.
- **Windows reports focus and keeps the display awake.** `XWindow.focused`
  follows `WM_ACTIVATEAPP` on the app's window, starting from whether the app
  holds the foreground, and `keepAwake` holds the display on with
  `SetThreadExecutionState` until it is released or the window is destroyed.
- **XWindow logs focus.** Each focus event logs `focused: <bool>` at info
  level, tagged `window`.
- **A bare domain leaves out the letters glued to it.** On Android and
  Windows, a host in `XUrl.match` ends at a change between Chinese, Japanese,
  Korean, Thai, Lao, Khmer or Myanmar letters and other characters inside a
  label, and leaves out the labels in these scripts that begin or end it and
  the `.` beside them, so a domain written straight before, after or between
  such text opens the right host: `访问example.com，然后`, `example.com然后`,
  `请看example.com.谢谢` and `ข้อมูลที่example.com` link `http://example.com`,
  and `访问example.com和google.com` links `http://example.com` and
  `http://google.com`, as on macOS. A host that begins or ends with a label in
  these scripts beside labels of other characters, such as `例子.com` or
  `example.中国`, is not linked, as on macOS. Such a label between a host's
  other labels stays in it, as in `www.例子.com`. A port these letters follow
  stays in the link: `访问example.com:8080然后` links
  `http://example.com:8080`, as on macOS.
- **A web link keeps the slash that ends it.** On Android and Windows, a web
  match that text follows keeps its path's trailing `/`, the other path
  punctuation a URL may end in, such as `?`, `=`, `#`, `-` and `*`, and a
  trailing `)` it opens, as on macOS. A link typed with a trailing `/` is
  complete when a space is typed after it.
- **A web link ends before CJK punctuation.** On every platform, `XUrl.match`
  ends a web match before ideographic, fullwidth and halfwidth punctuation
  such as `。`, `，`, `、`, `；`, `：`, `！` and `？`, and starts a bare domain
  match after one. A link ending a Chinese sentence opens without the mark and
  the text after it, and a link typed before one of these marks is complete
  when the mark is typed.
- **A web link leaves out the period after it.** On Android and Windows, and
  for the bare domains with a path that macOS matches beside `NSDataDetector`,
  `XUrl.match` ends a web match before a trailing `.`, `,`, `;` or `!` and
  before a trailing `)` the link does not open. A link that ends a sentence
  opens without the period, and a link typed before one of these marks is
  complete when the mark is typed.
- **Windows probes images.** `XImageProbe.size` and `XImageProbe.thumbnail`
  answer on Windows through WIC, upright with the image's orientation applied,
  for every format an installed codec decodes, HEIC and HEIF included where
  Windows has the HEIF and HEVC extensions, and null for a file none decodes.
  `XImageProbe.supported` is true on Windows, and the file dialog's `image/*`
  filter there allows heic and heif.
- **Windows extracts video frames and exports videos.** `XFiles.videoThumbnail`
  and `videoThumbnails` decode through Media Foundation the frame nearest each
  time, within 500 ms, upright, scaled to `maxWidth` or baked with the transform
  and overlay as on Apple platforms. `XVideoExporter` re-encodes every request
  on Windows to an H.264/AAC MP4, trimmed from the trim start exactly, without
  audio when muted, and with the transform and overlay drawn upright, at
  `videoBitrate` or else the source's bitrate, at least 0.1 bit per pixel per
  frame. Progress runs from 0 to 1, `done` answers the path, the size and the
  duration, and `cancel` deletes the partial file and fails with `cancelled`.
  Where Windows has no Media Foundation, each fails with its error.
- **Windows plays videos.** `XVideoPlayerController.file` plays on Windows
  through Media Foundation's Media Engine into a Flutter texture. `initialize`
  answers the display size and the duration, with `rotationQuarterTurns` 0
  since the frames arrive upright, and fails with `decode_failed` for a file
  Windows cannot decode, an H.264 video stored at most 32 pixels wide or 16
  tall among them. Play, pause, seek, looping, volume and speed act as on
  the other platforms, and the player reports its state, size, completion and
  errors. Where Media Foundation is missing, as on a Windows N edition without
  the Media Feature Pack, `initialize` fails with `create_failed` while the
  rest of the plugin works.
- **A video player logs its metadata.** `XVideoPlayerController.initialize`
  logs `initialized` at info level, tagged `video`, with the player's handle,
  size, duration and quarter turns.
- **Windows picks, opens, saves and reveals files.** `XFiles.pick` and the new
  `XFiles.pickMultiple`, which returns the picked files in order or an empty
  list when the user cancels and which Windows alone serves, open the Windows
  file dialog, filtered by extension. `XFiles.open` launches the file's
  associated application through Windows's checks for a downloaded file,
  `saveCopy` copies through the save dialog, and `showInFolder` selects the file
  in Explorer. `supportsSaveCopy` and `supportsShowInFolder` are true on
  Windows.
- **ux has a Windows plugin.** The pubspec declares `windows: pluginClass:
  XPluginCApi`, built as `ux_plugin.dll` on the Windows SDK alone, for Windows
  10 1903 or later. `XUrl.match` detects web, email and phone links there with
  AOSP's `Patterns.WEB_URL`, `EMAIL_ADDRESS` and `PHONE`, as Android does, so a
  bare domain is a link where macOS's detector leaves it plain. `XUrl.launch`
  opens a URL with the handler Windows has for its scheme, and
  `openAppSettings` answers false. `windows/test` holds the plugin's native
  tests.
- **Avatar editors close on accept.** `ComposeResult.imageBytes` is a
  `Future<Uint8List>` encoded after `ComposePage` pops, so the caller shows
  progress where the image lands; it fails with a `FormatException` when the
  image cannot be decoded. `MediaPickerPage.maxImageExtent` and
  `ComposePage.maxImageExtent` bound the longest edge of those bytes.
  Breaking: `ComposeResult.imageBytes` is a future, and
  `ComposeEntry.resolveImageBytes` is replaced by `ComposeEntry.captureImage`.
- **Avatar editors confirm with the app's primary button.** `ComposePage`
  lays `MediaHost.confirmButton` full width under the editing tools wherever
  no caption field sends the edit. Breaking: hosts implement
  `MediaHost.confirmButton`, and `MediaCommandsBar.onConfirm` is removed.
- **Network video players open without blocking the UI on iOS and macOS.**
  The player loads the video's rotation once the header has downloaded, and
  `initialize` reports it with the size and duration.
- **A video player's size is its display size.** `XVideoPlayerValue.size`,
  `XVideoPlayerMetadata.size` and `XVideoPlayerSizeChanged.size` are the
  dimensions after the track's rotation on every platform, so a portrait
  recording reports portrait. `rotationQuarterTurns` is the correction
  `XVideoPlayerView` applies to the texture: the track's rotation on iOS and
  macOS, 0 on Android, where the texture arrives upright. Size a box from
  `size` alone, without swapping it on odd turns.
- **A disposed video player stays disposed.** A native player created after
  `XVideoPlayerController.dispose` is disposed at once, and no listener hears
  from the controller after `dispose`. A call the native side answers after
  `dispose`, `initialize` included, changes nothing and fails with
  `XVideoPlayerException('disposed')`. Disposing a player while its
  `initialize` waits for the video fails that `initialize` with
  `XVideoPlayerException('disposed')`.
- **A disposed compose entry stays disposed.** A `ComposeEntry` disposed
  while its video, crop poster, draw overlay or composite is still loading
  neither notifies nor changes its state, and releases a poster that arrives
  late. `ComposeEntry.captureImage` returns null once the entry is disposed.
  The last `ComposeEntry.releaseVideo` drops the player and notifies before
  the native player finishes tearing down.
- **A compose entry captures the edits its preview is still rendering.**
  `ComposeEntry.composedImage` and `ComposeEntry.captureImage` wait for the
  render of the current edits, and a render an edit overtakes is discarded.
- **A video compose entry decodes its crop poster once.** Tools opened
  together share the one poster.
- **A compose entry deletes the draw overlays it keeps.** A video
  `ComposeEntry` writes its draw overlay PNG into the temporary directory's
  `ux_compose` folder. It deletes the PNG when a later draw apply replaces or
  clears it and when the entry is disposed, a PNG still being written
  included. `ComposePage`'s submit hands the overlay over with
  `ComposeResult.videoEdit` through `ComposeEntry.handOverVideoEdit`, and the
  receiver deletes `VideoEditValues.overlay`'s file once used.
- **A media surface ready again after its open flight shows its live pixels.**
  A `MediaFlightSurface` whose `ready` turns false after `GalleryTransition`'s
  open flight captures it, and true again once the flight ends, shows its live
  pixels as it turns ready, with no snapshot of the flight over them.
- **An image behind its own repaint boundary takes over from the open flight's
  snapshot.** When an image in a `MediaFlightSurface` sits behind a
  `RepaintBoundary` of its own and decodes after `GalleryTransition`'s open
  flight ends, the flight hands its snapshot off to the image as it decodes.
- **A camera cell that leaves the tree has no rect.** `CameraCellSource.rect`
  is null from the moment the picker drops its camera cell, so a `CameraPage`
  that leaves in that frame, as one a sign-out removes together with its
  picker does, closes toward where the cell was as it opened.
- **The screen that shows holds focus, so keys reach it.** When a
  `ScreenStack`'s top screen shows, its focus scope takes focus if focus is in
  the stack, on a scope around it, or nowhere, as when `XApp` starts, and asks
  for no keyboard. A stack inside a screen other than the top one, such as a
  covered `SheetScreen`'s, draws no focus into itself from outside it. Tab moves
  to the screen's first control, and Enter and Space activate it. `XApp`'s
  default shortcuts, actions and text-editing shortcuts sit above its overlay,
  so they reach entries a host inserts through `overlayKey`.
- **Esc goes back.** Esc pops the top screen where it `isModal`, and otherwise
  goes to `XRouter.backDispatcher`, as system back does. Esc in a focused text
  field unfocuses it, and a handler nearer the focus takes Esc first; one
  disabled for it, such as a `Scaffold`'s with no drawer open, hands Esc on to
  the nearest enabled one around it. A `ScreenStack` with no modal screen to
  pop hands Esc on to the one around it, so Esc in a modal `SheetScreen` pops
  the sheet.
- **A `ScreenShell` keeps screens it hosts but does not show.**
  `ScreenShell.hosted` lists every screen a shell hosts and `pages` the ones
  it shows. A hosted screen left out of `pages` stays mounted offstage with
  its State, unpainted, out of hit testing and focus, its tickers muted. It
  hides, shows again and leaves at once, without a transition, and focus
  inside it goes back to the shell. `ScreenShell.pagesChanged` tells the
  router that the shown screens changed outside a push or a pop, and the
  router re-renders and recomputes the active screen, the system-back state
  and the orientations. `XRouter.hosted` lists every screen the router holds,
  and `XRouter.pages` the shown ones. `popAll` pops hidden screens too, and a
  push equal to a screen `home` hosts asks it to `ScreenShell.show` that
  screen.
- **A `ScreenShell` places its hosted screens and hosts screens beside it.**
  `ScreenShell.place` wraps a hosted screen's slot to lay out where it draws,
  under the window's `MediaQuery`. A screen `ScreenShell.isBeside` marks
  moves no focus as it comes and goes, except that focus inside one that
  leaves goes to the shell. Tab and Shift+Tab cross between the shell and the
  screen, and the screen takes no edge-swipe or predictive-back drag, so back
  goes to the shell rather than the screen. A screen keeps its State when
  its placement, its beside mark or the shape of its transition changes.
  `ScreenStack` takes `hidden`, `beside` and `place`.
- **A back gesture moves a screen with the finger.** The iOS edge swipe
  moves a screen by the finger's travel since the touch went down.
  `ScreenSlot.curved(context, animation, curve)` is `animation` on `curve`:
  while a back gesture drives the slot it is the gesture's own progress, and
  once the gesture lets go, or the screen leaves, it runs the curve from where
  the screen shows to where the transition settles. `ScreenTransitions` take
  their curves through it. The spring back returns over 150 ms on the
  transition's curve.
- **A back gesture its screen stops taking is cancelled.** An iOS edge swipe
  or a predictive back that its screen stops taking before it lets go springs
  the screen back over 150 ms, and its release or commit pops nothing. A
  screen stops taking it as `canPop` turns false through
  `XRouter.pagesChanged`, and as it stops being shown: as it or a screen it
  sits in is covered, hidden or leaves. An edge swipe is cancelled as
  `canSwipeBack` turns false too, while a predictive back goes on and its
  commit goes back through `handleBack`, as system back does. A screen that
  leaves during one goes from where the gesture left it.
- **A predictive back asks the screen's `handleBack`.** Android's predictive
  back drags a screen only where its `canSwipeBack` holds, as the iOS edge
  swipe does; on any other screen it goes back as system back does, through
  `handleBack`. A predictive back's commit asks the screen's `handleBack`
  before it pops, and one that `handleBack` consumes springs the screen back
  over 150 ms.
- **Back inside a `SheetScreen` goes to its nested page.** System back on a
  `SheetScreen` with a nested page asks that page's `handleBack`, and pops the
  page only where `handleBack` declines and its `canPop` holds.
- **A screen takes no back gesture that a page inside it takes.** A screen
  takes an edge swipe or a predictive back only while it is shown, the top
  one or one shown beside it in every `ScreenStack` around it, and takes
  none while a `ScreenStack` inside it, or inside a screen shown beside it,
  shows a screen above its home. So a predictive back on a sheet asks its
  nested page's `handleBack` once, and one on a page pushed over the sheet
  pops that page alone.
- **System back goes to a page inside a screen first.** System back, and Esc
  no `ScreenStack` takes, go to the top screen of the innermost `ScreenStack`
  that shows a screen above its home inside the shown screens, which
  `ScreenStackState.nestedTop` names: `XRouter.backDispatcher` asks its
  `handleBack`, then pops it where its `canPop` holds. Where there is none,
  the top pushed screen's `handleBack` takes back, or the screen pops where
  its `canPop` holds and stays where it does not. So system back in a wide
  `ScreenShell` asks a page in its beside screen's `ScreenStack` before the
  shell.
- **A back gesture reads `canSwipeBack` as it starts.** The iOS edge swipe
  reads the screen's `canSwipeBack` as the touch goes down or the trackpad pan
  starts, as Android's predictive back reads it as the gesture starts, so a
  screen whose `canSwipeBack` changes needs no router rebuild. The edge swipe
  reads it again as it moves and lifts, and adds no semantics node.
- **An `XApp` over another `XRouter` shows that router's screens.** An `XApp`
  rebuilt with another `router` shows that router's screens, which take no
  State from the old router's, and the old router's screens leave the tree.
  An `XApp` over a router whose screens left the tree shows them again. Across
  a change of `defaultTargetPlatform`, an `XApp` keeps its router's screens
  and their State.
- **A media caption is what the host's caption field holds.**
  `ComposeResult.caption` is what `MediaHost.caption` reads from the item's
  caption controller when the page submits, in the host's own type: the host
  trims it and keeps what its field holds beside the text, such as formats.
  Breaking: hosts implement `MediaHost.caption`, and `ComposeResult.caption`
  is an `Object?`.
- **A pane builds only its own children.** A pane's children rebuild in a
  `BuildScope` of its `PaneElement`'s own as the pane lays out, so
  `Pane.buildChild` and `Pane.flushLayoutSync` build no widget outside the
  pane: one dirty beside a pane laid out in a post-frame callback rebuilds on
  the next frame.
- **`swipelab_webp` comes from GitHub.** ux depends on `swipelab_webp` from
  the git repository https://github.com/swipelab/swipelab_webp, so it
  resolves with no sibling checkout. A host that also depends on
  `swipelab_webp` names the same git source or overrides it.

### 0.17.0
- **`media.dart` holds one snapshot flight.** `GalleryTransition` uses
  `MediaFlightSurface` for current media pixels, `MediaFlightChrome` for
  stationary controls, and `HiddenMedia` for source visibility.
  `kMediaFlightDuration` is the shared 300 ms camera, compose and gallery
  route duration. `GallerySource.borderRadius` supplies the source shape.
  Picker snapshots retain the full bitmap so image quality upgrades preserve
  framing. Without an opening snapshot, media fades at its destination.
  Breaking: `GalleryOpenTransition`, `GalleryCloseTransition`,
  `kGalleryOpenChrome`, `kGalleryOpenPosition`, `kGalleryOpenBounds`,
  `kGalleryOpenPushed`, `kGalleryOpenCopyAlpha`, `kGalleryCloseSpatial` and
  `kGalleryCloseChrome` are removed; hosts use `GalleryTransition` and
  implement `GallerySource.borderRadius`.

### 0.16.0
- **`media.dart` holds the live picker camera cell.** `MediaPickerPage`
  shows a two-row preview with granted or limited photo access, lends its
  `CameraSession` to `CameraPage`, and sends captures through `ComposePage`
  with the picker's filter, purpose and submission handler. `CameraCell`
  and `CameraCellSource` carry the animated preview between grid and camera;
  cancellation returns to the picker with its gallery selection intact.
  `CameraPage` supports borrowed sessions and image-only or video-only capture.
  Permission views use host colours, text and strings, and foreground return
  refreshes camera and photo access. `XCameraController` exposes
  `cameraPermissionGranted()` without prompting or opening a session, and
  `requestCameraPermission()` with a Settings fallback. New development
  dependency: `cupertino_icons` for test fonts. Breaking: hosts implement
  `MediaStrings.cameraAccessRationale`, `photoAccessTitle`, `allowPhotoAccess`,
  `openSettings`, `limitedPhotosRationale` and `manage`, render
  `Screen.buildTransition` and call `Screen.onRemoved` after exit (through
  `XRouter`/`ScreenStack` or a Navigator route using `ScreenSlot` with
  `maintainState: true`), and declare Android `android.permission.CAMERA`,
  Apple `NSCameraUsageDescription` in `Info.plist`, and macOS
  `com.apple.security.device.camera` in debug and release entitlements; custom `XCameraBackend` implementations
  supply `cameraPermissionGranted()` and `requestCameraPermission()`.

### 0.15.0
- **`media.dart` holds the media picker and the camera.** `MediaPickerPage`
  with its albums screen, grid cell, selected strip, permission views,
  `SelectionContext` and `ThumbnailCache`; `CameraPage` with the shutter, flash
  and photo/video controls, `CameraThumb` and `normalizeCameraCapture`.
  `MediaHost` gains `lifecycle` and `isWideScreen`. New dependencies:
  `collection`, and `swipelab_webp` from the sibling checkout
  `../swipelab_webp`, so the package is `publish_to: none`. Breaking: a
  `MediaHost` implements the two new members.

### 0.14.0
- **`media.dart` holds the compose page.** `ComposePage` and `ComposeEntry`
  with the crop and draw tool screens and the video trim scrubber; the gallery
  open and close transition with `GallerySource`; `DismissCarrier`,
  `HiddenMediaController`, the video painters, `XMedia` and the gallery timing
  constants. `MediaHost` gains `push`, `captionController`, `captionField` and
  `keyboardInsets`. New dependencies: `path`, `path_provider`. Breaking: a
  `MediaHost` implements the four new members.

### 0.13.0
- **`media.dart` holds the image editors.** `Editor` with its crop, draw and
  text tools: `CropImageLayer`, `DrawImageLayer`, `EntityLayer`, their
  gestures, controls and painters, `Animator`, `CameraFit` and the text
  entity model. `MediaHost` gains `insets` and the text `family`. New
  dependencies: `flutter_svg`, `vector_math`. The brush illustrations ship as
  package assets.

### 0.12.0
- **`media.dart`.** `MediaHost`, through which the media flow reads the
  hosting app's colours, type, icons and strings, with `Touch`,
  `CountOdometer`, `MediaCommandsBar`, `MicPermissionBanner`, the EXIF
  orientation reader and `VideoEditValues`.

### 0.11.0
- **`ux.dart` is pure.** It exports core, reactive, navi, anim and the
  geometry helpers, and compiles for the web. Each native component is
  imported from its own library: `audio.dart`, `camera.dart`,
  `screen_sources.dart`, `video.dart`, `image.dart`, `clipboard.dart`,
  `crypto.dart`, `notifications.dart`, `secure_store.dart`, `window.dart`,
  `drop.dart`, `file.dart`, `gallery.dart`, `keyboard.dart`, `scanner.dart`,
  `shortcuts.dart`, `url.dart`, `sensor.dart`, `crash.dart`, `log.dart`,
  `app_group.dart`. Breaking: add the library a symbol lives in.

### 0.10.0
- **Apple host executables export dart:ffi process symbols.** Keyboard,
  sensor, and URL-detect entry points are looked up in the process; the
  host app's release strip keeps globals (`STRIP_STYLE = non-global`).
- **`XAudioCapture` picks its source.** `sources()` lists the hardware inputs
  the OS names plus, on macOS and Android 10+, one `playback` source for what
  the device plays; `start({sourceId})` opens it. Omitting `sourceId` is the
  default microphone under the platform voice processing. A
  microphone id opens that input, also under voice processing; the playback id
  taps the output raw — macOS through an audio-only `SCStream` under the
  screen-recording grant, Android through a media-projection consent the
  plugin asks for itself. iOS lists no playback source. Frames stay mono
  16 kHz Int16 of 320 samples, one source at a time: changing source is `stop`
  then `start`, and an id naming nothing throws `unknown_source`.
- **`XAudioCapture.start({voiceProcessing})`.** The default microphone and a
  microphone id capture under the platform voice processing when
  `voiceProcessing` is true (the default): Apple enables the voice-processing
  I/O unit, Android records `VOICE_COMMUNICATION` with echo cancellation.
  False leaves the microphone raw — no echo cancellation and no output
  ducking. A playback tap stays raw.
- **`Sheet` arbitrates drags against the attached scroll view by that
  view's own axis.** A down-drag scrolls a list with content left in that
  direction from every snap, while an up-drag from a non-expanded snap
  expands the sheet first. The same gesture hands off at an edge. A reversed
  list (a chat transcript) scrolls toward older content on a down-drag;
  sheet-chrome drags move the sheet, decided by the pointer that opens the
  gesture; and a displaced sheet keeps the gesture until it returns to its
  snap.
- **Darwin sources unified and moved to Swift Package Manager.** iOS and macOS
  now build from one package at `darwin/ux/` (`sharedDarwinSource: true`);
  `ios/` and `macos/` are gone, as are both podspecs — the plugin no longer
  supports CocoaPods. Consumers on a recent Flutter get SPM automatically and
  can `pod deintegrate`. `ZIPFoundation` is now an SPM dependency (macOS only).
  Removes the podspec copy-mirror of `darwin/{Camera,Video,File}` into
  `Classes/*-shared`, which existed only because CocoaPods cannot glob through
  symlinks — SPM reads the shared sources directly, so they can no longer go
  stale between builds.
- `XGallery.saveToLibrary(path, kind, mimeType?)`: add a file on disk to the
  system photo library. iOS requests add-only authorization (`.addOnly`
  "Allow Adding Photos?" prompt) then `performChanges`; Android inserts via
  `MediaStore` under `Pictures/<app>` / `Movies/<app>` (`IS_PENDING` flow on
  API 29+, `WRITE_EXTERNAL_STORAGE` + public-dir copy + media-scan below).
  Returns `XGallerySaveStatus {saved, denied}`; hard failures throw.
  `XGallery.supportsSaveToLibrary` gates UI (iOS / Android).
- `XFiles.saveCopy(path, mimeType?)`: save a user-visible copy of any file.
  iOS presents the system export picker ("Save to Files"); Android inserts
  into the Downloads collection (API 29+) or copies into public Downloads
  behind a `WRITE_EXTERNAL_STORAGE` grant (<29); macOS presents an
  `NSSavePanel` and copies to the chosen destination. Returns
  `XFileSaveStatus {saved, cancelled, denied}`. Gated by
  `XFiles.supportsSaveCopy` (iOS / Android / macOS).
- `XFiles.supportsShare`: capability gate for the existing `share` sheet
  (iOS / Android / macOS).
- `FakeXGalleryBackend`: implements `saveToLibrary`, records calls in
  `savedToLibrary`, outcome overridable via `onSaveToLibrary`.
- `XScreenSources`: the displays and windows a screen-share picker offers, as
  one snapshot over `ux/screen_sources` (macOS 14+). `list(allowedDisplayIds:,
  allowedWindowIds:, thumbnailWidth:, thumbnailHeight:)` intersects the
  caller's allow-sets with what is on screen and returns each survivor as an
  id, kind, title, owning application, source pixel dimensions and an
  aspect-fit PNG thumbnail; a source whose thumbnail fails to render comes back
  with a null `thumbnailPng`, and `thumbnail_failed` is thrown only when no
  requested source rendered. `list` never prompts — `hasPermission` /
  `requestPermission` are explicit. `XScreenSourcesBackend.instance` is
  settable and `FakeXScreenSourcesBackend` ships in `package:ux/testing.dart`.
- `XCameraEffects`: none / blur / dim behind the person on the outgoing camera
  track, over `ux/camera_effects` (+`/events`) (macOS 12+). `setEffect(trackId,
  effect)` hands the local video track to the native processor and `clear()`
  gives it back its own frames; `status` (`idle`/`applying`/`active`/`failed`)
  is the processor's account of the frames. Compositing is Core Image with a
  Vision person mask, and a failure falls back to the last good effected frame
  or black, never the raw input. The host app supplies its camera stack by
  conforming to `CameraEffectsBridge` and calling `CameraEffects.install(_:)`;
  without it commands answer `integration_unavailable`.
  `XCameraEffectsBackend.instance` is settable and `FakeXCameraEffectsBackend`
  ships in `package:ux/testing.dart`.

### 0.9.0
- `XScanner`: new platform-view widget for QR-code (and forward-compat
  barcode) scanning. iOS uses `AVCaptureMetadataOutput` (no extra pod);
  Android uses CameraX preview + ZXing decoder
  (`com.google.zxing:core:3.5.3`, ~470 KB jar, no Play Services dep).
  `XScannerPermission.requestCamera()` requests OS permission first;
  decoded payloads stream through `EventChannel('ux/scanner/events')`.

### 0.8.0
- `Log`: pretty, production-ready logger. Static entry (`Log.d/i/w/e/f/t`),
  scoped loggers via `Log.tag('KB')`, lazy messages (`Log.d(() => expensive)`),
  structured `fields`, ANSI-colored `ConsoleSink`, `DeveloperSink` for DevTools,
  `MemorySink` ring buffer (tests + breadcrumbs), `NoopSink`. Sinks fan out via
  `+` with per-sink `minLevel`; throwing sinks can't take down the pipeline.
- `Log.configure`: one-call setup that also wires `FlutterError.onError`,
  `PlatformDispatcher.onError`, and isolate errors through `Log.e`. Pair of
  log-then-rethrow is deduped via an `Expando` mark so crash handlers don't
  double-report. Override the `captureCrashes` hook to customise or pass
  `() {}` to opt out.
- `XKeyboard`: adaptive-learning debug output now uses `Log.tag('KB').d`
  instead of `print`, lazy-built so the formatted line is only constructed
  when debug level is enabled.

### 0.7.0
- `AutoMap<K, V>`: insertion-ordered collection with O(1) lookup by key
  **and** by index. Backed by a `List<V>` + `Map<K, int>` kept in sync by
  four mutation methods (`add`, `addAll`, `remove`, `clear`); both fields
  are private so callers cannot break the invariant. Extends `Iterable<V>`
  for `where` / `map` / `firstWhere` / etc. `remove` is O(n) to preserve
  order; every other op is O(1).

### 0.6.0
- `XFile`: new module for handing files to the OS
  - `XFile.share(path, {title, mimeType, sourceRect})` — iOS `UIActivityViewController`,
    macOS `NSSharingServicePicker`, Android `Intent.ACTION_SEND` via FileProvider.
    `sourceRect` anchors the popover on iPad / macOS.
  - `XFile.open(path, {mimeType})` — in-app preview where possible:
    iOS `QLPreviewController`, macOS `QLPreviewPanel` (preview on top of the app,
    no foreground loss), Android `Intent.ACTION_VIEW` with MIME inference from
    `MimeTypeMap` + a fallback set of text/code extensions so unknown types
    still resolve to `text/plain` instead of `application/octet-stream`.
- **macOS**: new platform. Plugin registry + `FilePlugin`; keyboard and sensor
  plugins remain iOS-only.
- Android: ships a FileProvider under `${applicationId}.ux.fileprovider`
  scoped to `ux_share/` in the app cache — host apps don't need manifest
  plumbing.
- iOS: `XWindow` helper (`keyWindow` / `topViewController`) in
  `NativePlugin.swift`, shared between keyboard and file plugins.

### 0.5.0
- `XSensor.orientation`: accelerometer-driven physical device rotation,
  independent of the OS auto-rotate setting or UI orientation lock
- `AppInfo`: version + buildNumber surface
- `XKeyboard`: focus tracking integration

### 0.4.0
- `package:ux/testing.dart`: new entry point for test-only utilities
- `matchesTextGolden(path, {update})`: `matchesGoldenFile`-style matcher for
  plain-text snapshots (RPC responses, log output, formatted data). Writes on
  first run or when `update: true`; compares byte-for-byte otherwise. Runtime
  stays flutter_test-free — depends only on `package:matcher`. For
  flutter_test users, pass `update: autoUpdateGoldenFiles` so
  `flutter test --update-goldens` regenerates text goldens too.

### 0.3.0
- `XKeyboard`: fix interactive dismiss race conditions — keyboard height no longer
  gets stuck when rapidly dismissing and re-focusing
- `XKeyboard`: handle zero-duration keyboard notifications (instant snap)
- `XKeyboard`: gate adaptive learning debug output behind `kDebugMode`
- Example: rewrite as chat UI demonstrating `ListenableBuilder`, scroll freeze,
  and interactive dismiss
- Example: modernize Android project (v2 embedding, AGP 8.7, Gradle 8.11)

### 0.2.0
- `XKeyboard`: sampled native animation curves (iOS & Android) with adaptive learning
- `XKeyboard`: interactive dismiss via pan gesture
- Android: keyboard height tracking via JNI/FFI bridge

### 0.1.1
- Bezier utilities

### 0.0.3
- Action Plan

### 0.0.2
- BendBox

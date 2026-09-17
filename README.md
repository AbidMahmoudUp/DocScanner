# ScanFlow — offline document scanner

A Flutter document scanner that runs entirely on the device: live paper-edge
detection, perspective correction, image enhancement, local storage, and PDF /
JPG export. Pages come from the camera or from photos already in the gallery.
No network calls, no cloud, no account.

- **State management:** Provider, MVVM
- **Image processing:** OpenCV (`opencv_core` / dartcv), in a background isolate
- **Storage:** page images on disk + SQLite (`sqflite`) metadata
- **Platform:** Android (API 24+)

## How it works

```
camera frame (YUV420, Y plane)
   → decimate to ≤640px on the camera isolate   (LumaFrame)
   → fit and divide out a first-order light gradient
   → propose outlines from several segmentations in parallel:
        Canny edges · Otsu on the flattened image
        (+ paper-by-colour and saturation-only, when colour is available)
   → score every candidate against one shared edge map
   → live outline on screen; auto-capture once it holds still

capture (full-res JPEG) OR photo picked from the gallery
   → detect outline again on the sharp image
   → user confirms / drags the corners
   → getPerspectiveTransform + warpPerspective   (deskew)
   → estimate illumination, divide it out         (shadows gone, paper white)
   → level stretch via a single LUT               (black point, white point,
                                                   brightness, contrast)
   → unsharp mask                                 (crisp text)
   → JPEG + thumbnail written to disk, row inserted in SQLite
```

Detection runs on a downscaled copy (longest side 640px) because accuracy
plateaus well before full resolution, and the resulting outline is stored
normalized (0..1) so it applies unchanged to the full-size capture.

## Finding the page

Detection **proposes and then scores**, rather than taking the first strategy
that returns something. No single segmentation is reliable across real scenes:
Canny finds crisp borders on a contrasting surface but vanishes on
white-on-white, Otsu copes with low contrast but smears under uneven light, and
neither notices that a brown desk and a white page are obviously different
colours. With a first-match ordering, a poor answer from an early strategy beats
a good answer from a later one — so every strategy proposes candidates, and one
shared edge map ranks them all.

Three things make the difference in practice:

- **Divide out the light gradient first.** A plane is fitted to the luminance
  and divided out. A plane can model a desk's falloff but cannot represent the
  step between desk and paper, so the page boundary survives while the gradient
  that makes a global threshold impossible does not. Without this, the page in
  shadow is darker than the desk in the light and no single cutoff exists.
- **Use colour.** Paper is bright *and* almost unsaturated. A saturation-only
  mask is the one segmentation that is invariant to how brightly a region is
  lit — scaling all three channels leaves saturation unchanged — so a shadow
  falling across half the page destroys every brightness-based method and
  leaves this one intact. Live preview frames carry only luma, but the capture
  is in colour, and the capture is what defines the crop.
- **Rank measured outlines above fallbacks.** Each contour also contributes its
  minimum-area rectangle, which rescues pages with a rounded, clipped or
  thumb-covered corner. But a rotated rectangle cannot represent perspective,
  so on an angled page it always overshoots — and it can still out-score the
  true outline. It is therefore only consulted when no measured outline is
  acceptable.

Accuracy is measured, not asserted: `integration_test/detection_test.dart`
builds scenes with a known outline and reports mean corner error as a fraction
of the frame. Current results, all well inside the 3.5% tolerance:

| scene | error |
|---|---|
| page on dark wood | 0.33% |
| page on light oak (low brightness contrast) | 0.12% |
| page on a grey table (low contrast either way) | 0.18% |
| page on coloured cloth | 0.32% |
| page shot at a steep angle | 0.22% |
| page with a shadow across it | 0.33% |
| skewed + light oak + shadow | 0.11% |
| equiluminant yellow desk | 0.13% (luma alone: not found) |
| empty desk | correctly reports nothing |

**Gallery import goes through the identical path.** A picked photo is copied
into the captures folder first, so from there on nothing downstream can tell it
from a camera shot. Picking several reviews them one at a time rather than
applying an unseen crop to a batch.

## The scan look

A photo of a page is not a scan. It carries the phone's own shadow, a
brightness gradient across the sheet, and grey-ish paper. Turning that into
something that reads as scanned is three steps, and the first is the one that
matters:

1. **Divide out the illumination.** Estimate what the page would look like with
   no ink on it, then divide the photo by that estimate. Paper goes to white
   wherever it is, so the shadow disappears instead of being merely lightened.
2. **Stretch the levels.** Take the black and white points off the histogram —
   paper dominates a page, so its bright end *is* the paper — and map them to
   0 and 255 through a single 256-entry LUT that also carries brightness and
   contrast. One lookup, no intermediate 8-bit rounding to lose faint strokes.
3. **Unsharp mask.** Puts back the edge definition the warp's interpolation
   softens. This is most of what makes text read as crisp rather than just dark.

The filters differ only in what they do with the result. **Colour** is the
default and applies the correction to all three channels from one luma-derived
background, so stamps, signatures and highlighter survive; colour is the
default because discarding it is destructive and cannot be undone from the
saved page. **Mono** renders the same correction neutral, **Grayscale** is a
plain desaturation, and **B&W text** adds an adaptive threshold for dense text
and OCR.

Flattening pulls every channel toward the paper's white point, which
desaturates whatever colour was there, so Colour finishes with a modest
saturation lift to pay that back. Paper is near-neutral, so it is barely
touched — and a test asserts it picks up no cast.

**Estimating the background needs two stages,** because one morphological close
cannot do it. A kernel small enough to follow a hard shadow edge cannot span a
solid logo, so the logo's interior looks like paper and gets divided away — it
comes back as a white box with a black outline. A kernel wide enough to span
the logo is far too smooth to track the shadow. So a wide close is used only to
decide *where the ink is*, and the illumination is then rebuilt across that ink
by inpainting from the paper around it.

**Brightness and contrast** live on the Enhance tab, open by default. Contrast
moves the black and white points rather than applying a gain around mid-grey:
after the level stretch ink already sits at 0 and paper at 255, so a mid-tone
gain would have nothing left to act on. Narrowing the span is what actually
thickens text and cleans paper — and it is what a scanner's contrast does.

**Clearing the border band matters more than it looks.** Blur, morphology and
threshold all extrapolate past the image boundary, leaving a ring of set pixels
that traces the frame. That ring is a perfect rectangle enclosing everything,
so it wins "largest contour" and every detection returns the whole image.
Erasing the band removes the contour instead of trying to recognise it later.

## A binding gotcha worth knowing

`dartcv` defaults `morphologyEx`'s `borderValue` to `0`, where OpenCV's own C++
default is `+inf`. The erode half of a close therefore darkens a band as wide
as the kernel all the way around the image. With the large kernel the
background estimate uses, that is most of the page — and every derived mask is
wrong near an edge.

This is why the OpenCV calls here pass `borderType: cv.BORDER_REPLICATE`
explicitly. It is also why the enhancement is covered by an **on-device**
integration test: a desktop Python prototype of the same pipeline produced
completely different (correct) numbers, so it could not have caught this.

```bash
flutter drive --driver=test_driver/integration_test.dart   --target=integration_test/cv_pipeline_test.dart --profile -d <device>
flutter drive --driver=test_driver/integration_test.dart   --target=integration_test/detection_test.dart --profile -d <device>
```

Profile mode rather than debug: the debug APK carries an 80MB kernel blob and
will not fit an emulator's install budget.

## Real-device notes

Things that only bite on hardware, and what the code does about them:

- **Frame copies.** A 1080p Y plane is ~2MB, and it would be copied once out of
  the platform's reused buffer and again across the isolate boundary — several
  times a second. `LumaFrame.fromPlane` decimates while it unpacks, so what
  crosses is ~130KB.
- **Peak memory.** A 12MP capture holds the decode, the warp and the filter
  output at once. `CvOps.outputMaxSide` caps the working size at 2400px (≈300
  DPI across A4), which is the standard scan resolution anyway.
- **Losing the camera.** Android hands the device to whatever asked last, so
  returning from the background can leave a controller that reports itself
  initialized but no longer owns the camera. A failed `startImageStream`
  rebuilds the controller from scratch.
- **Focus.** Pages are shot close-range, exactly where centre-weighted
  autofocus hunts. Tap the preview to pin focus and exposure.
- **Capture vs. stream.** The image stream is stopped before `takePicture`;
  several devices fail the capture otherwise.
- **Auto-capture re-arming.** After a shot, auto-capture disarms until the page
  leaves the frame or a different one appears — otherwise a document left under
  a steady camera is photographed again the instant the preview resumes.

## The scan flow

```
camera or gallery
   → detect the page
   → sweep animation: read the original, hand over the result
   → adjust: crop corners · rotate · filter · brightness · contrast
   → save sheet: name it, and pick any extra copies
   → land on the document, showing every page you just scanned
```

The **sweep** (`views/widgets/scan_reveal.dart`) plays once, when the first
rendered result arrives. A bar travels down the captured photo with the
detected outline drawn on it, then the photo gives way to the finished page.

The two images are deliberately *not* cross-dissolved under the bar, which is
the obvious implementation. The capture still has the desk in it and the result
is cropped and deskewed, so the two never line up and a wipe between them reads
as a glitch rather than a scan. Sweeping first and swapping second keeps both
images honest. A tap skips it — nobody wants to watch it twice.

The screen opens on **Enhance** rather than Crop, because that is where the
sweep lands: you see the result, then correct it if you need to.

The **save sheet** asks for a name and for any extra copies — photo gallery, or
a PDF handed to the share sheet so it can go to Files, Drive or email. The
library copy is not offered as a choice: the app has to keep it for the
document to exist at all, and a checkbox that cannot be unticked is just noise.
When the session is adding pages to an existing document the name is fixed, and
the sheet says so instead of asking for one it would throw away.

Extra copies are attempted **after** the library save succeeds, so a gallery
permission refusal or a full disk reports itself without taking the scan down
with it.

## Project layout

```
lib/
  core/app_theme.dart            design tokens, light + dark themes
  data/
    models/                      Quad, EnhanceSettings, ScanDocument, ScanPage
    local/                       sqflite schema, file layout
    repositories/                the only place rows, files and rendering meet
  services/
    cv/cv_ops.dart               pure OpenCV functions (isolate-safe)
    cv/cv_worker.dart            long-lived isolate, job queue
    cv/luma_frame.dart           camera frame packing + decimation (pure Dart)
    export/export_service.dart   PDF, gallery, share sheet
    import/image_import_service  gallery picker → captures folder
  viewmodels/                    one per screen + scan session + settings
  views/
    scan_flow.dart               capture/import → review → save navigation
    widgets/scan_reveal.dart     the scanner sweep
    preview/widgets/save_sheet   name + where extra copies go
    home/                        screen 1 — library, search, tags, multi-select
    camera/                      screen 2 — live preview, detection, shutter
    preview/                     screen 3 — crop and enhance
    details/                     screen 4 — page viewer, rename, export, delete
```

**MVVM boundaries.** Views only read view models and call their methods. View
models never touch sqflite, the file system or OpenCV — they go through
`DocumentRepository` and `CvWorker`. That keeps the pipeline testable and means
a screen can be rebuilt without touching storage logic.

## Why a persistent isolate

Live detection runs several times a second. A `compute()` call spawns and tears
down an isolate every time, which would eat the budget the detection itself
needs, so `CvWorker` spawns one isolate at startup and answers jobs by id.
Frames that arrive while a detection is in flight are dropped rather than
queued, so latency stays flat instead of building a backlog.

## Running it

```bash
flutter pub get
flutter run -d <android-device>
```

Tests:

```bash
flutter test          # units + widget tests: quad ordering, frame decimation,
                      # card layout across text scales, the sweep's handover
```

The OpenCV pipeline is tested on a device instead — see the section above.

### Android build notes

Two pins in the Gradle config are deliberate:

- `ndkVersion = "26.3.11579264"` in `android/app/build.gradle.kts` and mirrored
  onto plugin modules in `android/build.gradle.kts`. `opencv_core` builds its
  native library with `ANDROID_STL=c++_static`, which fails to link against the
  NDK 28 toolchain Flutter defaults to.
- `permission_handler: ^12.0.1`. Version 13 ships an Android build script that
  requires AGP 9 / Kotlin 2.3, ahead of the current Flutter template.

`abiFilters` is limited to `armeabi-v7a`, `arm64-v8a` and `x86_64` — the ABIs
OpenCV ships prebuilt binaries for — and honours
`flutter build apk --target-platform ...`, since each ABI carries ~70MB of
native libraries.

Gallery import needs no storage permission on Android 13+: `image_picker` uses
the system Photo Picker, which grants access only to the items chosen.

## Data and privacy

Everything stays in the app's private storage:

```
<app documents>/
  scans/<documentId>/page_<id>.jpg     enhanced page
  scans/<documentId>/thumb_<id>.jpg    list thumbnail
  scans/.trash/<documentId>/           deleted, pending undo
  captures/<id>.jpg                    raw capture, removed once saved
  exports/<name>.pdf                   generated, then handed to the share sheet
```

Deleting a document moves its folder to `.trash` with a rename (atomic on the
same volume) so undo never has to copy page images back; the folder is purged
once the undo snackbar goes away. Raw captures left behind by a session that
was killed mid-scan are swept at startup.

## Not included

OCR, e-signatures, annotation, team sharing, nested folders (tags are flat),
cloud backup.

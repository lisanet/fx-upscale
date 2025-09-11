# ↕️ fx-upscale

Metal-powered video upscaling

## Usage

```
USAGE: fx-upscale -i input-file [options]

OPTIONS:
  -i, --input <input>     input video file to upscale. This option is required.
  -o, --output <output>   output video file path.
                          If not specified, ' upscaled' is appended to the input file name.
  -w, --width <width>     width in pixels of output video.
                          If only width is specified, height is calculated proportionally.
  -h, --height <height>   height in pixels of output video.
                          If only height is specified, width is calculated proportionally.
  -s, --scale <factor>    scale factor (e.g. 2.0). Overrides width/height.
                          If neither width, height nor scale is given, the video is upscaled by factor 2.0
  -c, --codec <codec>     output codec: 'hevc', 'prores', or 'h264 (default: hevc)
  -q, --quality <quality> encoder quality 0 – 100. Applies to HEVC/H.264
  -g, --gop <size>        GOP size (default: let encoder decide the GOP size)
  -bf                     use B-frames. (default: off for HEVC/H.264 to improve scrubbing)
                          If you encounter scrubbing issues, remux the upscaled video, e.g using ffmpeg with this command: 
                          'ffmpeg -i upscaled_video.mp4 -c copy remuxed.mp4'
  -prio_speed             prioritize speed over quality
  -y                      overwrite output file
  --version               Show the version.
  --help                  Show help information.
```


> [!NOTE]
> Extremely large outputs are automatically converted to ProRes 422 and saved as `.mov` to ensure stability and compatibility. Specifically, outputs larger than roughly 118 megapixels (≈14.5K × 8.1K) force ProRes due to encoder limitations with H.264/HEVC at those sizes.

## Using B-frames
If you are using B-frames for your encodings, you might encounter issues with forward skipping in mpv-based players, e.g. IINA. You can fix this in three ways:

1. not using B-frames at all (the worst option)
2. remuxing the upscaled video using ffmpeg

```
ffmpeg -i upscaled.mp4 -c copy remuxed.mp4
```

3. changing the seek forward command in IINA. Backward skipping works as expected. For IINA and other mpv-based players, you can set the keybinding for the skip-forward action to:

```
seek 5 relative+exact
```

See the IINA Wiki: [Why is the seeking time not precise when pressing arrow keys?](https://github.com/iina/iina/wiki/FAQ#why-is-the-seeking-time-not-precise-when-pressing-arrow-keys). There’s also a screenshot of the corresponding settings dialog.

## Quality

When specifying `--quality`, values between 0 and 100 are accepted and mapped to VideoToolbox's `kVTCompressionPropertyKey_Quality`.
This effectively tunes constant-quality behavior, similar to CRF/CQ for H.264/HEVC via VideoToolbox. For ProRes, this setting is ignored.

## prio_speed

Using the option `--prio_speed` enables the VideoToolbox setting *'prioritize speed over quality'* `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`.
Although this may not sound preferable, the loss in quality is negligible for most encodings, especially when using the `--quality` option with a reasonable value above ~56. On Apple Silicon Macs, this results in a significant speed improvement.

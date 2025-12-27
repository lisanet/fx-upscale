## 🎞️ mx-upscale – Metal-Powered Video Upscaling

`mx-upscale` is a fast, Metal-based command-line tool for upscaling videos on macOS — optimized for Apple Silicon and modern GPUs.

### Project renamed

This tool was originally a fork of `fx-upscale`. Since then, I’ve added many new features that go far beyond what it used to be. Users who know the original tool might be confused about the differences, so I decided to rename this repository and tool to `mx-upscale` to better reflect the many changes and improvements it has gone through. Because `mx-upscale` uses MetalFX for its operations, the new name also highlights this foundation more clearly.


### ✅ Features

* GPU-accelerated Metal processing for ultra-fast video upscaling, cropping and sharpening  
* Automatic size calculation (keep aspect ratio if only width or height is given)  
* Supports `HEVC`, `H.264`, and `ProRes` codecs  
* Adjustable encoder quality (0-100)  
* Optional cropping before upscale  
* Optional sharpening after upscale
* Smart fallback to ProRes for very large outputs  
* Speed-priority mode for faster encoding with minimal quality loss  

### 🚀 Installation

There are several ways to install `mx-upscale`

1. **Downloading the release package**

    The easiest way to install `mx-upscale` is to download the latest release package.
   After downloading and unpacking the archive (by double-clicking it), you’ll need to remove the quarantine attribute to satisfy Apple’s Gatekeeper and then copy the binary to a folder in your PATH - usually `/usr/local/bin`.

   Assuming the unpacked `mx-upscale` binary is in your **Downloads** folder, run

   ```bash
    cd ~/Downloads
    xattr -c mx-upscale
    sudo cp mx-upscale /usr/local/bin
    ```
    
3. **Compiling from source**

   Clone the repo
   
   ```bash
   git clone https://github.com/lisanet/mx-upscale.git
   ```

   Then navigate to the directory and build the source

    ```bash
    cd mx-upscale
    ./build.sh -c release
    ```

    The resulting binary will be located in `.build/release/mx-upscale`. Finally, copy it into a directory in your PATH.

   ```bash
   sudo cp .build/release/mx-upscale /usr/local/bin
   ```


### ⚙️ Usage

```
USAGE: mx-upscale -i input-file [options]

FILE OPTIONS:
  -i, --input <input>     input video file to upscale. This option is required.
  -o, --output <output>   output video file path.
                          If not specified, ' upscaled' is appended to the input file name.
  -y, --overwrite         overwrite output file
  -a, --noaudio           Disable audio processing. The output file will have no audio tracks.
  --color_input <space>   expert option: input color space for SD content, if not autodected: 'pal' or 'ntsc' (default: auto)

SCALING OPTIONS:
  -w, --width <width>     width in pixels of output video.
                          If only width is specified, height is calculated proportionally.
  -h, --height <height>   height in pixels of output video.
                          If only height is specified, width is calculated proportionally.
  -t, --target <preset>   Scale to target resolution <preset>. 
                          Presets are: 'hd' (1280x720), 'fhd' (1920x1080), ' qhd' or 'wqhd' (2160x1440), '4k' or 'uhd' (3840x2160),
                           '8k' (7680x4320)
  -1, --square            Scale anamorphic video to square pixels when using --target
  -r, --crop <rect>       Crop rectangle 'width:height:left:top'. Applied before upscaling.
  -s, --sharpen <amount>  Sharpen video after upscaling. Recommended values: 0.7 - 1.2 (fhd) 

CODEC OPTIONS:
  -c, --codec <codec>     output codec: 'hevc', 'prores', or 'h264 (default: hevc)
  -q, --quality <quality> encoder quality 0 – 100. Applies to HEVC/H.264, ProRes is always lossless (default: 60)
  -g, --gop <size>        GOP size (default: let encoder decide the GOP size)
  -b, --bframes <bool>    use B-frames. You can use yes/no, true/false, 1/0 (default: yes)
  -p, --prio_speed <bool> prioritize speed over quality. You can use yes/no, true/false, 1/0 (default: yes)

OPTIONS:
  --quiet                 disable logging
  --version               Show the version.
  --help                  Show help information.
  ```


### ℹ️ Note

> **Large outputs:**  
> Videos exceeding ~118 megapixels (≈14.5K × 8.1K) are automatically encoded as **ProRes 422** and saved as `.mov` for stability and compatibility.  
> This avoids known encoder limits with `H.264` and `HEVC`.


### 🌟 Quality

The `--quality` option accepts values between **0–100**, mapping directly to VideoToolbox’s `kVTCompressionPropertyKey_Quality`.
This behaves similarly to `CRF/CQ` controls used in `H.264/HEVC`.  
For **ProRes**, this parameter is ignored.

For best results, use `--quality` values above **60**. Values above 90 will only increase file size with little or no noticeable visual improvement. 

The recommended value is **60**.

### ⚡ Speed-priority Mode

The `--prio_speed` option sets VideoToolbox’s `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`. You can use yes/no, true/false or 1/0 to enable/disable this option. The default is enabled.

While this slightly reduces theoretical quality, the visual impact is minimal — and encoding speed improves dramatically, especially on Apple Silicon.

### 🔪 Sharpening

The `--sharpen` option sharpens the video after it has been upscaled. It works only on the luminance channel and uses a threshold to avoid sharpening uniform areas, noise, and compression artifacts.

The optimal values depend on the upscaled resolution. Higher resolutions may allow the use of higher values.

Although most recent DVD content is already quite good, a small amount of additional sharpening can still provide visible benefits on TV screens. For upscaling DVD content to Full HD, recommended values range between 0.7 and 1.2, with 0.9 being a good and fairly safe starting point.

Use this option carefully to avoid oversharpening. 

### 🧪 Example

Upscale a 1080p video to 4K with very high quality. Verbose output.

```bash
mx-upscale -i input.mp4 -q 80 --target 4k -o output_4k.mov
```

Upscale a PAL video with 720x576 anamorphic encoded video to FullHD non-anamorph 1920x1080 with reasonable high quality (60) and using Speed-priority Mode and B-Frames. Be quiet, no info output

```bash
mx-upscale -i input.mp4 -width 1920 -height 1080 --quiet -o output_4k.mov
```

Upscale a 1080p letterboxed video, crop it before upscaling to 4K with aspect 2.39:1 and reasonable high quality, disabling Speed-priority Mode and using no B-Frames, verbose output

```bash
mx-upscale -i input.mp4 --crop 1920:800:0:0 -t 4k -q 60 -b 0 --prio_speed no -o output_4k.mov
```

Upscale a 576p DVD video to FHD with reasonable high quality, use speed mode an b-frames, sharpen slightly, verbose output

```bash
mx-upscale -i input.mp4 -t fhd -q 60 --sharpen 0.7 -o output_fhd.mp4
```

### 📬 License

CC0 1.0 Universal – feel free to use, modify, and distribute.


### 🤝 Contributing

Contributions, bug reports, and feature requests are welcome. Please open an issue or submit a pull request if you have any improvements or suggestions.

### ⚠️ Disclaimer

`mx-upscale` is provided **'as is'** without any warranty.  
Use at your own risk and ensure you have backups of your original media.

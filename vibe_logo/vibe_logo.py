#!/usr/bin/env python3
import argparse
from pathlib import Path
import numpy as np
import skimage.io

def generate_base_text(text='VIBE', fontsize=50):

    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    font_path = 'FrutigerNeueLTPro-Regular.otf'  # Your font path goes here

    plt.rcParams['font.family'] = 'sans-serif'

    font_path = Path('.').joinpath(font_path)

    if font_path.is_file():
        font_manager.fontManager.addfont(font_path)
        prop = font_manager.FontProperties(fname=font_path)
        plt.rcParams['font.sans-serif'] = prop.get_name()
    else:
        print(f"Warning: Font file '{font_path}' not found. Defaulting to Helvetica.")
        plt.rcParams['font.sans-serif'] = ['Helvetica']
    
    PAD = 10  # pixels of padding around the text

    # Render on a large canvas so the text fits comfortably
    fig, ax = plt.subplots(figsize=(20, 6))
    ax.text(0.5, 0.5, text, fontsize=fontsize, 
            #fontweight='bold',
            color='black',
            ha='center', va='center', transform=ax.transAxes)
    ax.axis('off')

    fig.canvas.draw()
    buf = np.frombuffer(fig.canvas.buffer_rgba(), dtype=np.uint8).copy()
    # Derive actual pixel dimensions from buffer (avoids get_width_height() DPI mismatch on macOS)
    n = buf.size // 4  # total pixels (4 bytes per RGBA pixel)
    fig_w_in, fig_h_in = fig.get_figwidth(), fig.get_figheight()
    h = int(round((n * fig_h_in / fig_w_in) ** 0.5))
    w = n // h
    img_array = buf.reshape(h, w, 4)#[:, :, :3]  # Drop alpha → RGB
    plt.close(fig)

    # Auto-crop to non-white pixels + padding
    mask = np.any(img_array < 250, axis=2)
    rows = np.where(mask.any(axis=1))[0]
    cols = np.where(mask.any(axis=0))[0]
    r0, r1 = max(rows[0] - PAD, 0), min(rows[-1] + PAD + 1, h)
    c0, c1 = max(cols[0] - PAD, 0), min(cols[-1] + PAD + 1, w)
    img_array = img_array[r0:r1, c0:c1]

    skimage.io.imsave('base_text.png', img_array)

    return img_array


def generate_logo(
    input_path: str,
    text: str | None,
    output_path: str,
    downscale: int,
    black_background: bool,
    final_width: int = 0,
    pad_frac: float = 0.05,
    added_padding: list[int] | None = None,
    added_padding_square: int | None = None,
    seed: int | None = None,
    rotate: float = 0.0,
    fontsize: int = 50,
):
    if downscale < 1:
        raise ValueError("downscale must be >= 1")
    
    if final_width < 0:
        raise ValueError("final width must be >= 1")

    # import, downscale, take alpha channel
    if text is not None:
        im = generate_base_text(text=text, fontsize=fontsize)
    else:
        im = skimage.io.imread(input_path)

    if im.ndim != 3 or im.shape[2] < 3:
        raise ValueError(
            f"Expected an RGB image with 3 channels; got shape {im.shape}"
        )

    im = im[::downscale, ::downscale, 2]
    im = (im < 250).astype(np.uint8)  # Binarize: text pixels become 1, background becomes 0
    #im = (im > 1).astype(np.uint8)

    # crop to nonzero content
    yp, xp = np.where(im)
    if yp.size == 0 or xp.size == 0:
        raise ValueError("No nonzero pixels found after binarization; check the input.")

    im = im[yp.min() : yp.max() + 1, xp.min() : xp.max() + 1]

    # pad
    pad = int(pad_frac * im.shape[1])
    im = np.pad(im, pad, mode="constant", constant_values=0)

    im = im * 100
    rgb_im = np.stack([im, im,im], axis=-1)

    # Define Pantone 192-ish RGB shades
    pantone_shades = np.array(
        [
            [255, 153, 178],  # Light Tint (+40% white)
            [240, 80, 120],   # Medium Tint (+20% white)
            [228, 0, 70],     # Base
            [180, 0, 55],     # Dark Tone (-20% brightness)
            [140, 0, 45],     # Deep Tone (-40% brightness)
        ],
        dtype=np.uint8,
    )

    rng = np.random.default_rng(seed)

    height, width = im.shape
    random_indices = rng.integers(0, len(pantone_shades), size=(height, width))

    image = pantone_shades[random_indices]  # (H, W, 3)

    # background
    if black_background:
        image[rgb_im.max(axis=-1) == 0] = 0
    else:
        image[rgb_im.max(axis=-1) == 0] = 255

    if final_width > 0:
        final_height = int(image.shape[0] * final_width / image.shape[1])
        image = skimage.transform.resize(image, (final_height, final_width), order=0, preserve_range=True)
    
    if added_padding_square is not None:
        image = np.pad(
            image,
            ((added_padding_square, added_padding_square), (added_padding_square, added_padding_square), (0, 0)),
            mode="constant",
            constant_values=255 if not black_background else 0,
        )
        if image.shape[0] <= image.shape[1]:
            added_padding_2 = (image.shape[1] - image.shape[0]) // 2
            image = np.pad(
                image,
                ((added_padding_2, added_padding_2), (0, 0), (0, 0)),
                mode="constant",
                constant_values=255 if not black_background else 0,
            )
        else:
            added_padding_2 = (image.shape[0] - image.shape[1]) // 2
            image = np.pad(
                image,
                ((0, 0), (added_padding_2, added_padding_2), (0, 0)),
                mode="constant",
                constant_values=255 if not black_background else 0,
            )

    elif added_padding is not None:
        pad_top, pad_bottom, pad_left, pad_right = added_padding
        image = np.pad(
            image,
            ((pad_top, pad_bottom), (pad_left, pad_right), (0, 0)),
            mode="constant",
            constant_values=255 if not black_background else 0,
        )

    if rotate != 0.0:
        image = skimage.transform.rotate(image, angle=rotate, resize=True, preserve_range=True).astype(np.uint8)
    
    skimage.io.imsave(output_path, image.astype(np.uint8))


def main():
    p = argparse.ArgumentParser(
        description="Generate a randomized Pantone-shaded logo image from an RGBA TIFF."
    )
    p.add_argument("--downscale", type=int, default=3, help="Downscale factor (>=1).")
    p.add_argument(
        "--black-background",
        action="store_true",
        help="Use black background (default is white).",
    )
    p.add_argument("--final-width", type=int, default=0, help="Set the final width.")
    p.add_argument("--pad-frac", type=float, default=0.05,
        help="Fractional padding to add around the logo before resizing.")
    p.add_argument("--added-padding", type=int, nargs=4, default=None,
        help="Additional padding (on top of final width) as top bottom left right.")
    p.add_argument("--added-padding-square", type=int, default=None,
        help="Additional square padding (on top of final width) to add on all sides.")
    p.add_argument(
        "--input",
        default="VIBE_logo_BW.tif",
        help="Input RGBA image path.",
    )
    p.add_argument(
        "--text",
        default=None,
        help="Text to render if no input image is provided.",
    )
    p.add_argument(
        "--output",
        default="vibe_logo2025.png",
        help="Output PNG path.",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for repeatable color assignment (optional).",
    )
    p.add_argument(
        "--rotate",
        type=float,
        default=0.0,
        help="Rotation angle in degrees (optional).",
    )
    p.add_argument(
        "--fontsize",
        type=int,
        default=50,
        help="Font size for text rendering (only applies if --text is used).",
    )
    args = p.parse_args()

    generate_logo(
        input_path=args.input,
        text=args.text,
        output_path=args.output,
        downscale=args.downscale,
        black_background=args.black_background,
        final_width=args.final_width,
        pad_frac=args.pad_frac,
        added_padding=args.added_padding,
        added_padding_square=args.added_padding_square,
        seed=args.seed,
        rotate=args.rotate,
        fontsize=args.fontsize,
    )


if __name__ == "__main__":
    main()

# Mac Themes identity

AppIcon.png was created with the built-in image-generation tool. The build converts
it into all standard macOS ICNS sizes using scripts/build-icon.sh. The menu-bar
counterpart is drawn as a monochrome template in Sources/MacThemes/BrandIcon.swift,
so macOS supplies the appropriate light, dark and selected-state color.

Generation prompt:

> Create a production macOS application icon for an app named Mac Themes. No text or letters. Square 1024x1024 image with true transparent background outside a centered rounded-square dark midnight indigo tile, tile inset 9% from canvas edges. Main symbol: three large overlapping rounded rectangular color-swatch cards, fanning gently from lower left to upper right, with the front card upright, luminous gradient from icy cyan to periwinkle, middle card violet, rear card warm coral peach. A tiny crisp four-point white sparkle near the upper right of the front card signifies customization. Premium restrained dimensional macOS icon, softly beveled glass/enamel surfaces, subtle shadows, beautifully balanced bold silhouette, high contrast at small sizes, clean controlled gradients. Straight-on view, no perspective scene, no mockup, no surrounding objects, no words, no paintbrush, no Apple logo. Keep the composition simple with generous padding. Save the result as a local project-ready PNG.

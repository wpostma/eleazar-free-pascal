#!/bin/bash
set -e

LAZRES=./tools/lazres
IMGDIR=./images

if [ ! -x "$LAZRES" ]; then
  echo "lazres not found, building it..."
  cd tools && make && cd ..
fi

echo "=== Rebuilding IDE image resources ==="

cd "$IMGDIR"

echo "  splash_logo.res ..."
../$LAZRES splash_logo.res splash_logo.png

echo "  laz_images.res ..."
../$LAZRES laz_images.res @laz_images_list.txt

echo "  components_images.res ..."
../$LAZRES components_images.res @components_images_list.txt

echo "  bookmark.res ..."
../$LAZRES bookmark.res sourceeditor/*.png

cd ..

# Force recompilation of units that embed resources
rm -f ide/main.ppu ide/splash.ppu ide/aboutfrm.ppu

echo "=== Done. Rebuild the IDE to pick up changes. ==="

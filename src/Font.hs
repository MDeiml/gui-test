module Font
    ( generateAtlas
    , getFontPath
    ) where

import           Control.Monad
import           Data.ByteArray                                      (withByteArray)
import qualified Data.ByteString                                     as BS
import           Data.List                                           (elemIndex,
                                                                      sortOn)
import           Data.Maybe
import           Foreign
import           Foreign.C.String
import           Graphics.Rendering.FreeType.Internal
import           Graphics.Rendering.FreeType.Internal.Bitmap
import           Graphics.Rendering.FreeType.Internal.Face
import qualified Graphics.Rendering.FreeType.Internal.GlyphMetrics   as GM
import           Graphics.Rendering.FreeType.Internal.GlyphSlot
import           Graphics.Rendering.FreeType.Internal.Library
import           Graphics.Rendering.FreeType.Internal.PrimitiveTypes
import           Graphics.Rendering.OpenGL                           (($=))
import qualified Graphics.Rendering.OpenGL                           as GL
import           Resources
import           System.IO.Unsafe
import           System.Process
import           Texture
import           Types

data Glyph = Glyph
    { gBitmap   :: [Word8]
    , gWidth    :: Int
    , gHeight   :: Int
    , gBearingX :: Int
    , gBearingY :: Int
    , gAdvance  :: Int
    , gCharcode :: Integer
    }

-- |getCharBitmap face index pixel_size
-- Loads glyph and renders it
getCharBitmap :: FT_Face -> FT_UInt -> Int -> IO Glyph
getCharBitmap ff index px = do
    runFreeType $ ft_Set_Pixel_Sizes ff (fromIntegral px) 0
    runFreeType $ ft_Load_Glyph ff index 0
    slot <- peek $ glyph ff
    m <- peek $ metrics slot
    let bx = fromIntegral (GM.horiBearingX m) `quot` 64
        by = fromIntegral (GM.horiBearingY m) `quot` 64
        ad = fromIntegral (GM.horiAdvance m) `quot` 64
    runFreeType $ ft_Render_Glyph slot ft_RENDER_MODE_NORMAL
    bmp <- peek $ bitmap slot
    let w = fromIntegral $ width bmp
        h = fromIntegral $ rows bmp
    bmp' <-
        forM [0 .. fromIntegral (w * h) - 1] $ \i ->
            peek $ buffer bmp `plusPtr` i :: IO Word8
    return
        Glyph
        { gBitmap = bmp'
        , gWidth = w
        , gHeight = h
        , gCharcode = 0
        , gBearingX = bx
        , gBearingY = by
        , gAdvance = ad
        }

-- |Loads all glyphs of the face in the given size
getCharBitmaps :: FT_Face -> Int -> IO [Glyph]
getCharBitmaps = getCharBitmaps' Nothing
  where
    getCharBitmaps' last ff px = do
        (char, index) <-
            alloca $ \i -> do
                c <-
                    maybe
                        (ft_Get_First_Char ff i)
                        (\l -> ft_Get_Next_Char ff l i)
                        last
                i' <- peek i
                return (c, i')
        if index == 0 || char >= 256
            then return []
            else do
                g <- getCharBitmap ff index px
                gs <- getCharBitmaps' (Just char) ff px
                return $ g {gCharcode = fromIntegral char} : gs

-- |Reorders Glyphs and combines their bitmaps
-- returns (bitmap, charcode -> (x, y, w, h, bearingX, bearingY, advance)
layoutGlyphs ::
       [Glyph] -> ([Word8], Integer -> (Int, Int, Int, Int, Int, Int, Int), Int)
layoutGlyphs glyphs =
    ( concat bmpFull'
    , \x ->
          fromMaybe (head metrics) $
          lookup x $ zip (map gCharcode sorted) metrics
    , size)
  where
    sorted = sortOn (negate . gHeight) glyphs
    ((bmp, pos), size) =
        head $
        catMaybes
            [ (\x -> (x, size)) <$> layoutGlyphs' size sorted 0 (0, 0) []
            | size <- [128,256 ..]
            ]
    bmpFull = map (\xs -> take size xs ++ replicate (size - length xs) 0) bmp
    bmpFull' =
        take size bmpFull ++
        replicate (size - length bmpFull) (replicate size 0)
    metrics =
        zipWith
            (\(a, b, c, d) e ->
                 (a, b, c, d, gBearingX e, gBearingY e, gAdvance e))
            pos
            sorted
    -- |Generates a square atlas bitmap (if padded with 0's)
    layoutGlyphs' ::
           Int -- atlas size
        -> [Glyph] -- glyphs
        -> Int -- max glyph height of this row
        -> (Int, Int) -- current coordinates in atlas
        -> [[Word8]] -- current atlas
        -> Maybe ([[Word8]], [(Int, Int, Int, Int)]) -- (bitmap, [(x, y, w, h)])
    layoutGlyphs' _ [] _ _ bmp' = Just (bmp', [])
    layoutGlyphs' size (g:gs) maxH0 (x, y) bmp' = do
        let h = gHeight g
            w = gWidth g
            maxH =
                if maxH0 == 0
                    then h
                    else maxH0
            (thisX, thisY, x', y', maxH') =
                if x + w > size
                    then (0, y + maxH + 1, w + 1, y + maxH + 1, h)
                    else (x, y, x + w + 1, y, max maxH h)
        if thisY + h > size
            then Nothing
            else do
                let bmp'' =
                        take thisY bmp' ++
                        zipWith3
                            (\a b c -> a ++ b ++ c)
                            (drop thisY bmp' ++ repeat [])
                            (comp w (gBitmap g) ++
                             replicate (maxH - h + 1) (replicate w 0))
                            (replicate (maxH + 1) [0])
                (bmpNext, pos') <- layoutGlyphs' size gs maxH' (x', y') bmp''
                return (bmpNext, (thisX, thisY, w, h) : pos')
    comp :: Int -> [a] -> [[a]]
    comp _ [] = []
    comp n xs = take n xs : comp n (drop n xs)

-- |Loads all glyphs of the given font file and puts them all in one texture
generateAtlas :: FilePath -> Int -> IO (Font Texture)
generateAtlas fp px = do
    ff <- fontFace fp
    asc <- peek $ ascender ff
    desc <- peek $ descender ff
    u <- peek $ units_per_EM ff
    glyphs <- getCharBitmaps ff px
    let (bmp, lu, size) = layoutGlyphs glyphs
        f = (/ fromIntegral size) . fromIntegral
    tex <- bitmapToTexture size size bmp
    return
        Font
        { glyphs =
              (\(x, y, w, h, _, _, _) ->
                   Texture tex (Bounds (f x) (f y) (f $ x + w) (f $ y + h))) .
              lu
        , fontMetrics = (\(_, _, w, h, x, y, a) -> (w, h, x, y, a)) . lu
        , ascent = (fromIntegral asc * px) `quot` fromIntegral u
        , descent = (fromIntegral desc * px) `quot` fromIntegral u
        , fontname = fp
        , fontsize = px
        }

bitmapToTexture :: Int -> Int -> [Word8] -> IO GL.TextureObject
bitmapToTexture w h bmp = do
    tex <- GL.genObjectName
    GL.textureBinding GL.Texture2D $= Just tex
    withByteArray (BS.pack bmp) $ \bmp' ->
        GL.texImage2D
            GL.Texture2D
            GL.NoProxy
            0
            GL.R8
            (GL.TextureSize2D (fromIntegral w) (fromIntegral h))
            0
            (GL.PixelData GL.Red GL.UnsignedByte bmp')
    GL.textureFilter GL.Texture2D $= ((GL.Linear', Nothing), GL.Linear')
    GL.textureWrapMode GL.Texture2D GL.S $= (GL.Repeated, GL.ClampToEdge)
    GL.textureWrapMode GL.Texture2D GL.T $= (GL.Repeated, GL.ClampToEdge)
    return tex

runFreeType :: IO FT_Error -> IO ()
runFreeType m = do
    r <- m
    unless (r == 0) $ fail $ "FreeType Error:" ++ show r

{-# NOINLINE freeType #-}
freeType :: FT_Library
freeType =
    unsafePerformIO $
    alloca $ \p -> do
        runFreeType $ ft_Init_FreeType p
        peek p

fontFace :: FilePath -> IO FT_Face
fontFace fp =
    withCString fp $ \str ->
        alloca $ \ptr -> do
            runFreeType $ ft_New_Face freeType str 0 ptr
            peek ptr

getFontPath :: String -> Bool -> Bool -> IO FilePath
getFontPath fontname bold italic = do
    out <- readProcess "fc-list" [fontname] ""
    let tokens = map (split ':') $ lines out
        styles = map (split ',' . drop (length "style=") . (!! 2)) tokens
        isBold = map (elem "Bold") styles
        isItalic = map (elem "Italic") styles
        isBoldItalic = map (elem "Bold Italic") styles
        bold' = bold && not italic
        italic' = italic && not bold
        boldItalic = bold && italic
        tokens' =
            map fst $
            filter ((== (bold', italic', boldItalic)) . snd) $
            zip tokens $ zip3 isBold isItalic isBoldItalic
        tokens'' = sortOn (\a -> length (a !! 1 ++ a !! 2)) tokens'
        paths = map head tokens''
    return (head paths)
  where
    split c s =
        case elemIndex c s of
            Nothing -> [s]
            Just i ->
                let (a, b) = splitAt i s
                in a : split c (tail b)

module GLFWRenderer
    ( module Renderer
    , GLFWRenderer
    ) where

import Control.Arrow ((***))
import Control.Monad
import Data.IORef
import Data.Word
import Drawable
import Font
import qualified Graphics.Rendering.OpenGL as GL
import Graphics.Rendering.OpenGL (($=))
import qualified Graphics.UI.GLFW as G
import Input
import Renderer
import Types

data GLFWRenderer = GLFWRenderer
    { window :: G.Window
    , events :: IORef [Event]
    , fonts :: IORef [((String, Int), Font)]
    }

color :: Word8 -> Word8 -> Word8 -> IO ()
color r g b =
    GL.color
        (GL.Color3 (realToFrac r) (realToFrac g) (realToFrac b) :: GL.Color3 GL.GLdouble)

vertex :: Float -> Float -> Float -> IO ()
vertex x y z =
    GL.vertex
        (GL.Vertex3 (realToFrac x) (realToFrac y) (realToFrac z) :: GL.Vertex3 GL.GLdouble)

texCoord :: Float -> Float -> IO ()
texCoord x y =
    GL.texCoord
        (GL.TexCoord2 (realToFrac x) (realToFrac y) :: GL.TexCoord2 GL.GLdouble)

instance Renderer GLFWRenderer where
    create title (w, h) = do
        _ <- G.init
        win <- G.createWindow w h title Nothing Nothing
        maybe
            (error "Window could not be crated")
            (\win' -> do
                 G.makeContextCurrent $ Just win'
                 GL.texture GL.Texture2D $= GL.Enabled
                 es <- newIORef []
                 fs <- newIORef []
                 G.setKeyCallback win' $ Just $ kc es
                 G.setMouseButtonCallback win' $ Just $ mc es
                 G.setCursorPosCallback win' $ Just $ mmc es
                 return GLFWRenderer {window = win', events = es, fonts = fs})
            win
      where
        kc es _win key _code ks _mod = do
            let ks' =
                    case ks of
                        G.KeyState'Pressed -> KeyDown
                        G.KeyState'Released -> KeyUp
                        G.KeyState'Repeating -> KeyRepeat
                event = KeyEvent key ks'
            modifyIORef es (event :)
        mc es win button bs _mod = do
            (x, y) <- G.getCursorPos win
            let bs' =
                    case bs of
                        G.MouseButtonState'Pressed -> ButtonDown
                        G.MouseButtonState'Released -> ButtonUp
                button' = fromEnum button
                event =
                    MouseEvent
                        button'
                        bs'
                        (Coords (realToFrac x) (realToFrac y))
            modifyIORef es (event :)
        mmc es win x y =
            let event = MouseMoveEvent (Coords (realToFrac x) (realToFrac y))
            in modifyIORef es (event :)
    render re (DrawShape (Color r g b) (Rect (Bounds x0 y0 x1 y1))) = do
        (w, h) <- G.getFramebufferSize $ window re
        G.makeContextCurrent $ Just $ window re
        GL.loadIdentity
        GL.ortho 0 (fromIntegral w) (fromIntegral h) 0 1 (-1)
        GL.renderPrimitive GL.Quads $ do
            color r g b
            vertex x0 y0 0
            vertex x1 y0 0
            vertex x1 y1 0
            vertex x0 y1 0
    render re (DrawShape (Color r g b) (Text text fontname (Coords x y) size)) = do
        (w, h) <- G.getFramebufferSize $ window re
        G.makeContextCurrent $ Just $ window re
        fs <- readIORef $ fonts re
        f <-
            case lookup (fontname, size) fs of
                Just f' -> return f'
                Nothing -> do
                    f' <- generateAtlas fontname size
                    writeIORef (fonts re) $ ((fontname, size), f') : fs
                    return f'
        GL.loadIdentity
        GL.ortho 0 (fromIntegral w) (fromIntegral h) 0 1 (-1)
        GL.renderPrimitive GL.Quads $ do
            when False $ color r g b
            foldM_
                (\x' c -> do
                     let (x0, y0, x1, y1) = charCoords f c
                         fi = fromIntegral
                         (w, h, bx, by, a) =
                             let (a1, a2, a3, a4, a5) = fontMetrics f c
                             in (fi a1, fi a2, fi a3, fi a4, fi a5)
                         y' = y + fromIntegral (ascent f) - by
                         x'' = x' + bx
                     texCoord x0 y0
                     vertex x'' y' 0
                     texCoord x1 y0
                     vertex (x'' + w) y' 0
                     texCoord x1 y1
                     vertex (x'' + w) (y' + h) 0
                     texCoord x0 y1
                     vertex x'' (y' + h) 0
                     return (x' + a))
                x $
                map (fromIntegral . fromEnum) text
    clear r = do
        G.makeContextCurrent $ Just $ window r
        GL.clear [GL.ColorBuffer]
    swapBuffers r = G.swapBuffers $ window r
    getSize r = do
        (w, h) <- G.getFramebufferSize $ window r
        return (fromIntegral w, fromIntegral h)
    closing r = G.windowShouldClose $ window r
    pollEvents r = do
        G.makeContextCurrent $ Just $ window r
        G.pollEvents
        es <- readIORef $ events r
        writeIORef (events r) []
        return es

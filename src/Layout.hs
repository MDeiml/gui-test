{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE Rank2Types                #-}

module Layout
    ( LayoutParam(..)
    , Orientation(..)
    , Align(..)
    , Layout
    , Weight
    , widgetLayout
    , linearLayout
    , tableLayout
    , widgetLayout'
    , linearLayout'
    , tableLayout'
    , noLayout
    , stackLayout
    , stackLayout'
    , stdParams
    , constLayout
    , constLayout'
    ) where

import           Control.Arrow
import           Data.List     (transpose)
import           Data.Maybe    (mapMaybe)
import           Types
import           Widget

type Layout1 p1 p2 = [p1] -> (Bounds -> [Bounds], p2)

type Layout' p1 p2 a
     = forall m i o. Monad m =>
                         Widget (p1, Bool) m i o -> Widget (p2, Bool) m (i, a) o

type Layout p1 p2
     = forall m i o. Monad m =>
                         Widget (p1, Bool) m i o -> Widget (p2, Bool) m i o

type Margin = (Float, Float, Float, Float)

data Orientation
    = Horizontal
    | Vertical

data Align
    = AlignStart
    | AlignCenter
    | AlignEnd

stdParams :: LayoutParam
stdParams =
    LayoutParam
    {pWidth = 0, pHeight = 0, pWeightX = Nothing, pWeightY = Nothing}

constLayout :: (Eq p1) => Bounds -> Layout p1 p2
constLayout bs w =
    buildWidget' $ \i -> do
        ~(o, _, d) <- runWidget w i
        w' <- d (repeat bs)
        return (o, constLayout bs w')

constLayout' :: (Eq p1) => Layout' p1 p2 Bounds
constLayout' w =
    buildWidget' $ \(i, bs) -> do
        ~(o, _, d) <- runWidget w i
        w' <- d (repeat bs)
        return (o, constLayout' w')

noLayout :: (Eq p) => Layout p p
noLayout =
    widgetLayout $ \ps ->
        (\bs -> bs : replicate (length ps - 1) (Bounds 0 0 0 0), head ps)

widgetLayout :: (Eq p1) => Layout1 p1 p2 -> Layout p1 p2
widgetLayout f w = widgetLayout' (const f) w <<< arr (\x -> (x, ()))

widgetLayout' :: (a -> Layout1 p1 p2) -> Layout' p1 p2 a
widgetLayout' f' w = buildWidget $ runWidget' Nothing w
  where
    runWidget' mbs w0 (i, il) = do
        let f = f' il
        ~(o, ps0, d) <- runWidget w0 i
        let ps = map (\ ~(x, _) -> x) ps0
            reval = any (\ ~(_, x) -> x) ps0
            ~(~(calcBounds, p), reval') =
                case mbs of
                    Nothing -> (f ps, True)
                    Just ~(p', cb, b, bs) ->
                        if not reval
                            then ( ( \x ->
                                         if x == b
                                             then bs
                                             else cb x
                                   , p')
                                 , False)
                            else (f ps, True)
        return
            ( o
            , (p, reval')
            , \bs -> do
                  let bs' = calcBounds bs
                  w' <- d bs'
                  return $
                      buildWidget $
                      runWidget' (Just (p, calcBounds, bs, bs')) w')

stackLayout ::
       Margin
    -> (Align, Align)
    -> (Weight, Weight)
    -> Layout LayoutParam LayoutParam
stackLayout m a l = widgetLayout $ stackLayout1 m a l

stackLayout' ::
       Layout' LayoutParam LayoutParam ( Margin
                                       , (Align, Align)
                                       , (Weight, Weight))
stackLayout' = widgetLayout' $ \(a, b, c) -> stackLayout1 a b c

stackLayout1 ::
       Margin
    -> (Align, Align)
    -> (Weight, Weight)
    -> Layout1 LayoutParam LayoutParam
stackLayout1 (mt, mb, mr, ml) (ax, ay) (lx, ly) ps =
    (\bs -> map (calcBounds bs) ps, param)
  where
    pw = mr + ml + pWidth (head ps)
    ph = mt + mb + pHeight (head ps)
    param =
        LayoutParam {pWidth = pw, pHeight = ph, pWeightX = lx, pWeightY = ly}
    calcBounds (Bounds x0' y0' x1' y1') p = bs
      where
        x0 = x0' + ml
        y0 = y0' + mt
        x1 = x1' - mr
        y1 = y1' - mb
        bs = Bounds (xs + x0) (ys + y0) (xs + x0 + width) (ys + y0 + height)
        width =
            case pWeightX p of
                Nothing -> pWidth p
                Just 0 ->
                    case pWeightX (head ps) of
                        Nothing -> pWidth (head ps)
                        Just _  -> x1 - x0
                Just _ -> x1 - x0
        height =
            case pWeightY p of
                Nothing -> pHeight p
                Just 0 ->
                    case pWeightY (head ps) of
                        Nothing -> pHeight (head ps)
                        Just _  -> y1 - y0
                Just _ -> y1 - y0
        xs =
            case ax of
                AlignStart  -> 0
                AlignCenter -> ((x1 - x0) - width) / 2
                AlignEnd    -> (x1 - x0) - width
        ys =
            case ay of
                AlignStart  -> 0
                AlignCenter -> ((y1 - y0) - height) / 2
                AlignEnd    -> (y1 - y0) - height

linearLayout ::
       Orientation -> (Weight, Weight) -> Layout LayoutParam LayoutParam
linearLayout o l = widgetLayout $ linearLayout1 o l

linearLayout' :: Layout' LayoutParam LayoutParam (Orientation, (Weight, Weight))
linearLayout' = widgetLayout' $ uncurry linearLayout1

linearLayout1 ::
       Orientation -> (Weight, Weight) -> Layout1 LayoutParam LayoutParam
linearLayout1 o (lx, ly) ps = (calcBounds, param)
  where
    totalX = sum $ map pWidth ps
    totalY = sum $ map pHeight ps
    weightTotalX = sum $ mapMaybe pWeightX ps
    weightTotalY = sum $ mapMaybe pWeightY ps
    param =
        LayoutParam
        {pWidth = pWidth', pHeight = pHeight', pWeightX = lx, pWeightY = ly}
    pWidth' =
        case o of
            Vertical   -> maximum $ map pWidth ps
            Horizontal -> totalX
    pHeight' =
        case o of
            Horizontal -> maximum $ map pHeight ps
            Vertical   -> totalY
    calcBounds (Bounds x0 y0 x1 y1) =
        case o of
            Horizontal -> stackH x0 $ map calcBoundsH ps
            Vertical   -> stackV y0 $ map calcBoundsV ps
      where
        restX = (x1 - x0) - totalX
        restY = (y1 - y0) - totalY
        weightX = maybe 0 (\w -> restX / weightTotalX * w)
        weightY = maybe 0 (\w -> restY / weightTotalY * w)
        calcBoundsH p =
            Bounds
                0
                y0
                (pWidth p + weightX (pWeightX p))
                (y0 + maybe (pHeight p) (const $ y1 - y0) (pWeightY p))
        calcBoundsV p =
            Bounds
                x0
                0
                (x0 + maybe (pWidth p) (const $ x1 - x0) (pWeightX p))
                (pHeight p + weightY (pWeightY p))
        stackH _ [] = []
        stackH x (Bounds a0 b0 a1 b1:bs) =
            Bounds (a0 + x) b0 (a1 + x) b1 : stackH (a1 + x) bs
        stackV _ [] = []
        stackV y (Bounds a0 b0 a1 b1:bs) =
            Bounds a0 (b0 + y) a1 (b1 + y) : stackV (b1 + y) bs

-- data TableLayoutParam = TableLayoutParam {
--     tpColspan :: Int,
--     tpLayoutParam :: LayoutParam
-- }
tableLayout :: Int -> (Weight, Weight) -> Layout LayoutParam LayoutParam
tableLayout colwidth l = widgetLayout $ tableLayout1 colwidth l

tableLayout' :: Layout' LayoutParam LayoutParam (Int, (Weight, Weight))
tableLayout' = widgetLayout' $ uncurry tableLayout1

tableLayout1 :: Int -> (Weight, Weight) -> Layout1 LayoutParam LayoutParam
tableLayout1 colwidth (lx, ly) ps = (calcBounds, param)
  where
    ps' = reformat ps
    reformat [] = []
    reformat xs = take colwidth xs : reformat (drop colwidth xs)
    colWidths = map (maximum . map pWidth) $ transpose ps'
    colWeights = map (sum . mapMaybe pWeightX) $ transpose ps'
    rowHeights = map (maximum . map pHeight) ps'
    rowWeights = map (sum . mapMaybe pWeightY) ps'
    totalX = sum colWidths
    totalY = sum rowHeights
    totalWeightX = unzero $ sum colWeights
    totalWeightY = unzero $ sum rowWeights
    unzero 0 = 1
    unzero x = x
    param =
        LayoutParam
        {pWidth = totalX, pHeight = totalY, pWeightX = lx, pWeightY = ly}
    calcBounds (Bounds x0 y0 x1 y1) = concat bounds'
      where
        restX = (x1 - x0) - totalX
        restY = (y1 - y0) - totalY
        colWidths' =
            zipWith (+) colWidths $
            map (\w -> restX / totalWeightX * w) colWeights
        rowHeights' =
            zipWith (+) rowHeights $
            map (\w -> restY / totalWeightY * w) rowWeights
        widths =
            transpose $
            zipWith (\w p -> map (fx w) p) colWidths' $ transpose ps'
        heights = zipWith (\h p -> map (fy h) p) rowHeights' ps'
        fx w p =
            case pWeightX p of
                Nothing -> pWidth p
                Just _  -> w
        fy h p =
            case pWeightY p of
                Nothing -> pHeight p
                Just _  -> h
        bounds = zipWith (zipWith (Bounds 0 0)) widths heights
        bounds' =
            transpose $
            map (stackY rowHeights' y0) $
            transpose $ map (stackX colWidths' x0) bounds
        stackX _ _ [] = []
        stackX (w:ws) t (Bounds x0 y0 x1 y1:bs) =
            Bounds (x0 + t) y0 (x1 + t) y1 : stackX ws (w + t) bs
        stackX _ _ _ = error "ws must be same length as bs"
        stackY _ _ [] = []
        stackY (h:hs) t (Bounds x0 y0 x1 y1:bs) =
            Bounds x0 (y0 + t) x1 (y1 + t) : stackY hs (h + t) bs
        stackY _ _ _ = error "hs must be same length as bs"

{-# LANGUAGE TupleSections #-}
module Main (main) where

import Graphics.UI.SDL hiding (flip)
import qualified Graphics.UI.SDL as SDL
import Graphics.UI.SDL.Image

import Sound.ALUT hiding (get)
import qualified Sound.ALUT as ALUT

import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.List (intersect)

import Data.Ratio

import qualified Sound.MIDI.File.Load as Load
import qualified Sound.MIDI.File as F
import qualified Sound.MIDI.File.Event as E
import qualified Sound.MIDI.File.Event.Meta as M
import qualified Sound.MIDI.Message.Channel as C
import qualified Sound.MIDI.Message.Channel.Voice as V
import qualified Data.EventList.Relative.TimeBody as RTB
import qualified Data.EventList.Absolute.TimeBody as ATB

import Control.Monad
import Control.Monad.Trans.State
import Control.Monad.IO.Class
import Control.Arrow
import Data.Maybe

import System.Exit

import Paths_OnyxEdit

data Note
  = Kick Hit
  | Snare Hit
  | SnareFlam -- ^ Red/yellow, a double hit on snare
  | Tom YBG Hit
  | HihatF     -- ^ Foot
  | HihatC YBG -- ^ Closed
  | HihatO YBG -- ^ Open
  | Ride   YBG
  | Crash  YBG
  deriving (Eq, Ord, Show, Read)

data Hit = Normal | Ghost
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

data YBG = Yellow | Blue | Green
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

noteSprite :: Note -> (Int, Int)
noteSprite n = (30 * x, 0) where
  x = case n of
    Kick Normal -> 0
    Snare Normal -> 1
    SnareFlam -> 20
    Tom ybg Normal -> 2 + fromEnum ybg
    HihatF -> 19
    HihatC ybg -> 8 + fromEnum ybg
    HihatO ybg -> 11 + fromEnum ybg
    Ride ybg -> 25 + fromEnum ybg
    Crash ybg -> 5 + fromEnum ybg
    Kick Ghost -> 14
    Snare Ghost -> 15
    Tom ybg Ghost -> 16 + fromEnum ybg

type Seconds = Rational
type Beats   = Rational
type BPS     = Rational

-- | A position expressed in either real time or musical time.
data Position
  = Both Seconds Beats
  | Seconds Seconds
  | Beats Beats
  deriving (Show, Read)

-- | Comparing two positions will either compare their Seconds values, or their
-- Beats values, depending on which is present. Comparing a Seconds to a Beats
-- will raise an error.
instance Ord Position where
  compare (Both  s _) (Both  s' _) = compare s s' -- arbitrary
  compare (Both  s _) (Seconds s') = compare s s'
  compare (Both  _ b) (Beats   b') = compare b b'
  compare (Seconds s) (Both  s' _) = compare s s'
  compare (Seconds s) (Seconds s') = compare s s'
  compare (Seconds _) (Beats    _) =
    error "compare: can't compare Seconds and Beats"
  compare (Beats   b) (Both  _ b') = compare b b'
  compare (Beats   _) (Seconds  _) =
    error "compare: can't compare Seconds and Beats"
  compare (Beats   b) (Beats   b') = compare b b'

instance Eq Position where
  x == y = compare x y == EQ

toSeconds :: Position -> Seconds
toSeconds (Both s _) = s
toSeconds (Seconds s) = s
toSeconds (Beats _) = error "toSeconds: got Beats value"

toBeats :: Position -> Beats
toBeats (Both _ b) = b
toBeats (Beats b) = b
toBeats (Seconds _) = error "toBeats: got Seconds value"

positionTempos :: Map.Map Beats BPS -> Map.Map Position BPS
positionTempos = Map.fromDistinctAscList . f 0 0 2 . Map.toAscList where
  f :: Beats -> Seconds -> BPS -> [(Beats, BPS)] -> [(Position, BPS)]
  f bts secs bps xs = case xs of
    [] -> []
    (bts', bps') : xs' -> let
      secs' = secs + (bts' - bts) / bps
      in (Both secs' bts', bps') : f bts' secs' bps' xs'

positionTrack :: Map.Map Position BPS -> Map.Map Beats a -> Map.Map Position a
positionTrack tmps = Map.mapKeysMonotonic $
  \bts -> Both (beatsToSeconds' tmps bts) bts

secondsToBeats' :: Map.Map Position BPS -> Seconds -> Beats
secondsToBeats' tmps secs = case Map.lookupLE (Seconds secs) tmps of
  Nothing -> error "secondsToBeats: missing tempo"
  Just (Both secs' bts, bps) -> bts + (secs - secs') * bps
  Just _ -> error "secondsToBeats: invalidly stored tempo"

secondsToBeats :: Seconds -> Prog Beats
secondsToBeats secs = do
  tmps <- gets $ vTempos . vTracks
  return $ secondsToBeats' tmps secs

beatsToSeconds' :: Map.Map Position BPS -> Beats -> Seconds
beatsToSeconds' tmps bts = case Map.lookupLE (Beats bts) tmps of
  Nothing -> error "beatsToSeconds: missing tempo"
  Just (Both secs bts', bps) -> secs + (bts - bts') / bps
  Just _ -> error "beatsToSeconds: invalidly stored tempo"

beatsToSeconds :: Beats -> Prog Seconds
beatsToSeconds bts = do
  tmps <- gets $ vTempos . vTracks
  return $ beatsToSeconds' tmps bts

positionBoth :: Position -> Prog Position
positionBoth b@(Both _ _) = return b
positionBoth (Seconds  s) = secondsToBeats s >>= \b -> return $ Both s b
positionBoth (Beats    b) = beatsToSeconds b >>= \s -> return $ Both s b

data Tracks = Tracks
  { vTempos   :: Map.Map Position BPS
  , vDrums    :: Map.Map Position (Set.Set Note)
  , vTimeSigs :: Map.Map Position (Int, Beats)
  , vLines    :: Map.Map Position Line
  } deriving (Eq, Ord, Show, Read)

data Program = Program
  { vSurfaces   :: Surfaces
  , vSources    :: Sources
  , vTracks     :: Tracks
  , vPosition   :: Position
  , vEnd        :: Position
  , vResolution :: Int -- ^ Zoom level, in pixels (width) per second of time
  , vPlaying    :: Bool -- ^ Is audio currently playing?
  , vPlaySpeed  :: Rational
  , vDivision   :: Beats -- ^ The beat fraction that creates sub-beat lines.
  , vMetronome  :: Bool
  } deriving (Eq, Ord, Show)

makeMeasure :: Beats -> Beats -> (Int, Beats) -> Map.Map Beats Line
makeMeasure dvn start (mult, unit) = let
  len = fromIntegral mult * unit
  end = start + len
  subbeats = Map.fromDistinctAscList $ map (, SubBeat) $
    takeWhile (< end) [start, start + dvn ..]
  beats    = Map.fromDistinctAscList $ map (, Beat) $
    takeWhile (< end) [start, start + unit ..]
  measure = Map.singleton start Measure
  in measure `Map.union` beats `Map.union` subbeats

makeLines' :: Beats -> [(Beats, (Int, Beats))] -> Beats -> [(Beats, Line)]
makeLines' dvn sigs end = case sigs of
  [] -> []
  (bts, sig@(i, b)) : sigs' -> if bts >= end
    then []
    else let
      bts' = bts + fromIntegral i * b
      measure = Map.toAscList $ makeMeasure dvn bts sig
      in measure ++ case sigs' of
        (btsNext, _) : _ | bts' >= btsNext -> makeLines' dvn sigs' end
        _ -> makeLines' dvn ((bts', sig) : sigs') end

makeLines :: Prog ()
makeLines = do
  sigs <- fmap Map.toAscList $ gets $ vTimeSigs . vTracks
  dvn <- gets vDivision
  end <- gets vEnd
  let btLns = makeLines' dvn (map (first toBeats) sigs) (toBeats end)
  posLns <- forM btLns $ runKleisli $ first $ Kleisli $ positionBoth . Beats
  modify $ \prog ->
    prog { vTracks = (vTracks prog) { vLines = Map.fromList posLns } }

data Surfaces = Surfaces
  { vScreen     :: Surface
  , vNoteSheet  :: Surface
  , vBackground :: Surface
  , vStaff      :: Surface
  , vBeatLines  :: Surface
  , vNowLine    :: Surface
  } deriving (Eq, Ord, Show)

data Sources = Sources
  { vAudioStart :: Float
  , vDrumAudio  :: (Source, Source)
  , vSongAudio  :: (Source, Source)
  , vClick      :: Source
  } deriving (Eq, Ord, Show)

data Line = Measure | Beat | SubBeat
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

type Prog = StateT Program IO

loadImage :: String -> IO Surface
loadImage filename = load filename >>= displayFormatAlpha

apply :: Int -> Int -> Surface -> Surface -> IO Bool
apply x y src dst = blitSurface src Nothing dst (Just offset)
  where offset = Rect { rectX = x, rectY = y, rectW = 0, rectH = 0 }

timeToX :: Seconds -> Prog Int
timeToX pos = do
  now <- gets vPosition
  pps <- gets vResolution
  return $ 150 + floor ((pos - toSeconds now) * fromIntegral pps)

drawLine :: Position -> Line -> Prog ()
drawLine pos l = void $ do
  x <- timeToX $ toSeconds pos
  scrn <- gets $ vScreen . vSurfaces
  surf <- gets $ vBeatLines . vSurfaces
  let clip = Just $ case l of
        Measure -> Rect 0 0 30 125
        Beat    -> Rect 30 0 30 125
        SubBeat -> Rect 60 0 30 125
      drawAt = Just $ Rect (x - 15) 100 0 0
  liftIO $ blitSurface surf clip scrn drawAt

drawNote :: Position -> Note -> Prog Int
drawNote pos note = do
  surf <- gets $ vNoteSheet . vSurfaces
  scrn <- gets $ vScreen . vSurfaces
  x <- timeToX $ toSeconds pos
  let (clipX, clipY) = noteSprite note
      clip = Just $ Rect clipX clipY 30 125
      drawAt = Just $ Rect (x - 15) 100 0 0
  void $ liftIO $ blitSurface surf clip scrn drawAt
  return x

-- | Draws notes until it finds one that is definitely not visible.
drawVisibleNotes :: [(Position, Note)] -> Prog ()
drawVisibleNotes [] = return ()
drawVisibleNotes ((pos, note) : pns) = do
  x <- drawNote pos note
  when (-100 < x && x < 1100) $ drawVisibleNotes pns

drawNotes :: Prog ()
drawNotes = do
  notes <- gets $ vDrums . vTracks
  now <- gets vPosition
  case Map.splitLookup now notes of
    (lt, eq, gt) -> do
      drawLess lt
      maybe (return ()) (mapM_ (drawNote now) . Set.toList) eq
      drawMore gt
  where
    drawLess = drawVisibleNotes . expandSets . Map.toDescList
    drawMore = drawVisibleNotes . expandSets . Map.toAscList
    expandSets :: [(a, Set.Set b)] -> [(a, b)]
    expandSets = concatMap $ \(x, sy) -> map (x,) $ Set.toList sy 

{-
kitchen :: Map.Map Beats (Set.Set Note)
kitchen = Map.fromList
  [ (0  , Set.fromList [Kick Normal, Crash Green])
  , (0.5, Set.fromList [HihatF])
  , (1  , Set.fromList [Ride Blue])
  , (1.5, Set.fromList [Snare Normal])
  , (2  , Set.fromList [Ride Blue])
  , (2.5, Set.fromList [HihatO Yellow])
  , (3  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (3.5, Set.fromList [HihatC Yellow])
  , (4  , Set.fromList [Ride Blue])
  , (4.5, Set.fromList [Snare Normal])
  , (5  , Set.fromList [Ride Blue])
  , (5.5, Set.fromList [HihatO Yellow])
  , (6  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (6.5, Set.fromList [HihatC Yellow])
  , (7  , Set.fromList [Ride Blue])
  , (7.5, Set.fromList [Snare Normal])
  , (8  , Set.fromList [Ride Blue])
  , (8.5, Set.fromList [HihatO Yellow])
  , (9  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (9.5, Set.fromList [HihatC Yellow])
  , (10  , Set.fromList [Ride Blue])
  , (10.5, Set.fromList [Kick Normal])
  , (11  , Set.fromList [Snare Normal])
  , (11.5, Set.fromList [Snare Normal])
  , (12  , Set.fromList [Kick Normal, Crash Green])
  , (12.5, Set.fromList [HihatF])
  , (13  , Set.fromList [Ride Blue])
  , (13.5, Set.fromList [Snare Normal])
  , (14  , Set.fromList [Ride Blue])
  , (14.5, Set.fromList [HihatO Yellow])
  , (15  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (15.5, Set.fromList [HihatC Yellow])
  , (16  , Set.fromList [Ride Blue])
  , (16.5, Set.fromList [Snare Normal])
  , (17  , Set.fromList [Ride Blue])
  , (17.5, Set.fromList [HihatO Yellow])
  , (18  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (18.5, Set.fromList [HihatC Yellow])
  , (19  , Set.fromList [Ride Blue])
  , (19.5, Set.fromList [Snare Normal])
  , (20  , Set.fromList [Ride Blue])
  , (20.5, Set.fromList [HihatO Yellow])
  , (21  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (21.5, Set.fromList [HihatC Yellow])
  , (22  , Set.fromList [Ride Blue])
  , (22.5, Set.fromList [Kick Normal])
  , (23  , Set.fromList [Snare Normal])
  , (23.5, Set.fromList [Snare Normal])
  , (24  , Set.fromList [Kick Normal, Crash Green])
  , (24.5, Set.fromList [HihatF])
  , (25  , Set.fromList [Ride Blue])
  , (25.5, Set.fromList [Snare Normal])
  , (26  , Set.fromList [Ride Blue])
  , (26.5, Set.fromList [HihatO Yellow])
  , (27  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (27.5, Set.fromList [HihatC Yellow])
  , (28  , Set.fromList [Ride Blue])
  , (28.5, Set.fromList [Snare Normal])
  , (29  , Set.fromList [Ride Blue])
  , (29.5, Set.fromList [HihatO Yellow])
  , (30  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (30.5, Set.fromList [HihatC Yellow])
  , (31  , Set.fromList [Ride Blue])
  , (31.5, Set.fromList [Snare Normal])
  , (32  , Set.fromList [Ride Blue])
  , (32.5, Set.fromList [HihatO Yellow])
  , (33  , Set.fromList [Kick Normal, HihatF, Ride Blue])
  , (33.5, Set.fromList [HihatC Yellow])
  , (34  , Set.fromList [Ride Blue])
  , (34.5, Set.fromList [Kick Normal])
  , (35  , Set.fromList [SnareFlam])
  , (35.5, Set.fromList [SnareFlam])
  , (36  , Set.fromList [Kick Normal, Crash Green])
  , (36.5, Set.fromList [Ride Blue])
  , (37  , Set.fromList [Kick Normal, Ride Blue])
  , (37.5, Set.fromList [Snare Normal, Ride Blue])
  , (38  , Set.fromList [Ride Blue])
  , (38.5, Set.fromList [Kick Normal, Ride Blue])
  , (39  , Set.fromList [Kick Normal, Ride Blue])
  , (39.5, Set.fromList [Ride Blue])
  , (40  , Set.fromList [Kick Normal, Ride Blue])
  , (40.5, Set.fromList [Snare Normal, Ride Blue])
  , (41  , Set.fromList [Ride Blue])
  , (41.5, Set.fromList [Kick Normal, Ride Blue])
  , (42  , Set.fromList [Kick Normal, Ride Blue])
  , (42.5, Set.fromList [Ride Blue])
  , (43  , Set.fromList [Kick Normal, Ride Blue])
  , (43.5, Set.fromList [Snare Normal, Ride Blue])
  , (44  , Set.fromList [Ride Blue])
  , (44.5, Set.fromList [Kick Normal, Ride Blue])
  , (45  , Set.fromList [Snare Normal, Crash Yellow])
  , (45.5, Set.fromList [Snare Normal])
  , (45.75, Set.fromList [Snare Normal])
  , (46  , Set.fromList [Snare Normal])
  , (46.25, Set.fromList [Snare Normal])
  , (46.5, Set.fromList [Tom Yellow Normal])
  , (46.75, Set.fromList [Tom Yellow Normal])
  , (47, Set.fromList [Tom Blue Normal])
  , (47.25, Set.fromList [Tom Blue Normal])
  , (47.5, Set.fromList [Tom Green Normal])
  , (47.75, Set.fromList [Tom Green Normal])
  , (48, Set.fromList [Kick Normal, Crash Green])
  ]
-}

drawBG :: Prog ()
drawBG = void $ do
  scrn <- gets $ vScreen     . vSurfaces
  bg   <- gets $ vBackground . vSurfaces
  liftIO $ apply 0 0 bg scrn

drawLines :: Prog ()
drawLines = gets (vLines . vTracks) >>= mapM_ (uncurry drawLine) . Map.toList

drawStaff :: Prog ()
drawStaff = do
  scrn <- gets $ vScreen  . vSurfaces
  now  <- gets $ vNowLine . vSurfaces
  stf  <- gets $ vStaff   . vSurfaces
  void $ liftIO $ apply 0 100 stf scrn
  void $ liftIO $ apply (150 - 15) 0 now scrn

draw :: Prog ()
draw = do
  drawBG >> drawLines >> drawStaff >> drawNotes
  gets (vScreen . vSurfaces) >>= liftIO . SDL.flip

loadSource :: FilePath -> Source -> IO ()
loadSource f src = createBuffer (File f) >>= \buf -> buffer src $= Just buf

main :: IO ()
main = withInit [InitTimer, InitVideo] $
  withProgNameAndArgs runALUT $ \_ args -> do

    -- Get screen, load sprites
    scrn       <- setVideoMode 1000 480 32 [SWSurface]
    gemSheet   <- getDataFileName "gems.png"  >>= loadImage
    bgImage    <- getDataFileName "bg.png"    >>= loadImage
    staffImage <- getDataFileName "staff.png" >>= loadImage
    beat       <- getDataFileName "beat.png"  >>= loadImage
    now        <- getDataFileName "now.png"   >>= loadImage

    -- Load audio
    srcs@[srcDrumL, srcDrumR, srcSongL, srcSongR] <- genObjectNames 4
    let midPath : wavs@[_,_,_,_] = args
    zipWithM_ loadSource wavs srcs
    forM_ [srcDrumL, srcSongL] $ \src ->
      liftIO $ sourcePosition src $= Vertex3 (-1) 0 0
    forM_ [srcDrumR, srcSongR] $ \src ->
      liftIO $ sourcePosition src $= Vertex3 1 0 0
    [srcClick] <- genObjectNames 1
    clk <- getDataFileName "click.wav"
    loadSource clk srcClick

    -- Load MIDI
    mid <- Load.fromFile midPath

    let surfaces = Surfaces
          { vScreen     = scrn
          , vNoteSheet  = gemSheet
          , vBackground = bgImage
          , vStaff      = staffImage
          , vBeatLines  = beat
          , vNowLine    = now
          }
        sources = Sources
          { vAudioStart = 39.726
          , vDrumAudio  = (srcDrumL, srcDrumR)
          , vSongAudio  = (srcSongL, srcSongR)
          , vClick      = srcClick
          }
        prog = Program
          { vSurfaces   = surfaces
          , vSources    = sources
          , vTracks     = undefined
          , vPosition   = undefined
          , vEnd        = undefined
          , vResolution = 200
          , vPlaying    = False
          , vPlaySpeed  = 1
          , vDivision   = 1/4
          , vMetronome  = False
          }

    evalStateT (clearAll >> loadMIDI mid >> draw >> loopPaused) prog

setSpeed :: Rational -> Prog ()
setSpeed spd = do
  modify $ \prog -> prog { vPlaySpeed = spd }
  srcs <- allSources
  liftIO $ forM_ srcs $ \src -> pitch src $= realToFrac spd

setPosition :: Position -> Prog ()
setPosition pos = do
  strt <- gets $ vAudioStart . vSources
  let pos' = strt + realToFrac (toSeconds pos)
  modify $ \prog -> prog { vPosition = pos }
  srcs <- allSources
  liftIO $ forM_ srcs $ \src -> secOffset src $= pos'

setResolution :: Int -> Prog ()
setResolution res = modify $ \prog -> prog { vResolution = res }

modifyResolution :: (Int -> Int) -> Prog ()
modifyResolution f = gets vResolution >>= setResolution . f

modifySpeed :: (Rational -> Rational) -> Prog ()
modifySpeed f = gets vPlaySpeed >>= setSpeed . f

toggleSource :: Source -> Prog ()
toggleSource src = liftIO $ do
  g <- ALUT.get $ sourceGain src
  sourceGain src $= if g > 0.5 then 0 else 1

staffLines :: Note -> [Int]
staffLines n = case n of
  Kick Normal -> [0]
  Kick Ghost  -> [0, -1]
  Snare _     -> [1]
  SnareFlam   -> [1, 2]
  Tom  ybg _  -> [2 + fromEnum ybg]
  HihatF      -> [-1]
  HihatC ybg  -> [2 + fromEnum ybg]
  HihatO ybg  -> [2 + fromEnum ybg]
  Ride   ybg  -> [2 + fromEnum ybg]
  Crash  ybg  -> [2 + fromEnum ybg]

toggleNote :: Note -> Prog ()
toggleNote n = do
  now <- gets vPosition
  drms <- gets $ vDrums . vTracks
  let drms' = Map.alter f now drms
  modify $ \prog -> prog { vTracks = (vTracks prog) { vDrums = drms' } }
  where f Nothing = Just $ Set.singleton n
        f (Just notes) = if Set.member n notes
          then if Set.size notes == 1
            then Nothing
            else Just $ Set.delete n notes
          else let
            occupied = staffLines n
            in Just $ Set.insert n $
              Set.filter (null . intersect occupied . staffLines) notes

-- | The loop for a state that isn't in playing mode. We don't have to draw;
-- just handle the next event.
loopPaused :: Prog ()
loopPaused = do
  liftIO $ delay 1
  evt <- liftIO pollEvent
  case evt of
    Quit -> liftIO exitSuccess
    KeyDown (Keysym k _ _) -> case k of
      SDLK_UP -> modifyResolution (+ 20) >> draw >> loopPaused
      SDLK_DOWN -> modifyResolution (\r -> max 0 $ r - 20) >> draw >> loopPaused
      SDLK_LEFT -> modifySpeed (\spd -> max 0.1 $ spd - 0.1) >> loopPaused
      SDLK_RIGHT -> modifySpeed (\spd -> min 2 $ spd + 0.1) >> loopPaused
      SDLK_SPACE -> playAll >> loopPlaying
      SDLK_d -> do
        (srcDrumL, srcDrumR) <- gets $ vDrumAudio . vSources
        forM_ [srcDrumL, srcDrumR] toggleSource
        loopPaused
      SDLK_s -> do
        (srcSongL, srcSongR) <- gets $ vSongAudio . vSources
        forM_ [srcSongL, srcSongR] toggleSource
        loopPaused
      SDLK_z -> setPosition (Both 0 0) >> draw >> loopPaused
      SDLK_m -> do
        modify $ \prog -> prog { vMetronome = not $ vMetronome prog }
        loopPaused
      SDLK_q -> do
        dvn <- gets vDivision
        case (numerator dvn, denominator dvn) of
          (1, d) -> do
            modify $ \prog -> prog { vDivision = 1 % (d + 1) }
            makeLines
          _      -> return ()
        draw
        loopPaused
      SDLK_a -> do
        dvn <- gets vDivision
        case (numerator dvn, denominator dvn) of
          (1, d) | d >= 2 -> do
            modify $ \prog -> prog { vDivision = 1 % (d - 1) }
            makeLines
          _               -> return ()
        draw
        loopPaused
      SDLK_1 -> toggleNote (Kick Normal) >> draw >> loopPaused
      SDLK_2 -> toggleNote (Snare Normal) >> draw >> loopPaused
      _ -> loopPaused
    MouseButtonDown _ _ btn -> case btn of
      ButtonWheelDown -> do
        pos <- gets vPosition
        lns <- gets $ vLines . vTracks
        maybe (return ()) (setPosition . fst) $ Map.lookupGT pos lns
        draw
        loopPaused
      ButtonWheelUp -> do
        pos <- gets vPosition
        lns <- gets $ vLines . vTracks
        maybe (return ()) (setPosition . fst) $ Map.lookupLT pos lns
        draw
        loopPaused
      _ -> loopPaused
    _ -> loopPaused

-- | The loop for a state that is playing currently. We must start by updating
-- our position, and drawing the board.
loopPlaying :: Prog ()
loopPlaying = do
  liftIO $ delay 1
  updatePlaying
  draw
  evt <- liftIO pollEvent
  case evt of
    Quit -> liftIO exitSuccess
    KeyDown (Keysym k _ _) -> case k of
      SDLK_UP -> modifyResolution (+ 20) >> draw >> loopPlaying
      SDLK_DOWN -> modifyResolution (\r -> max 0 $ r - 20) >> draw >> loopPlaying
      SDLK_LEFT -> do
        pauseAll
        modifySpeed $ \spd -> max 0.1 $ spd - 0.1
        playAll
        loopPlaying
      SDLK_RIGHT -> do
        pauseAll
        modifySpeed $ \spd -> min 2 $ spd + 0.1
        playAll
        loopPlaying
      SDLK_SPACE -> pauseAll >> loopPaused
      SDLK_d -> do
        (srcDrumL, srcDrumR) <- gets $ vDrumAudio . vSources
        forM_ [srcDrumL, srcDrumR] toggleSource
        loopPlaying
      SDLK_s -> do
        (srcSongL, srcSongR) <- gets $ vSongAudio . vSources
        forM_ [srcSongL, srcSongR] toggleSource
        loopPlaying
      SDLK_z -> pauseAll >> setPosition (Both 0 0) >> playAll >> loopPlaying
      SDLK_m -> do
        modify $ \prog -> prog { vMetronome = not $ vMetronome prog }
        loopPlaying
      SDLK_q -> do
        dvn <- gets vDivision
        case (numerator dvn, denominator dvn) of
          (1, d) -> do
            modify $ \prog -> prog { vDivision = 1 % (d + 1) }
            makeLines
          _      -> return ()
        loopPlaying
      SDLK_a -> do
        dvn <- gets vDivision
        case (numerator dvn, denominator dvn) of
          (1, d) | d >= 2 -> do
            modify $ \prog -> prog { vDivision = 1 % (d - 1) }
            makeLines
          _               -> return ()
        loopPlaying
      _ -> loopPlaying
    MouseButtonDown _ _ btn -> case btn of
      ButtonWheelDown -> do
        pos <- gets vPosition
        lns <- gets $ vLines . vTracks
        case Map.splitLookup pos lns of
          (_, _, gt) -> case reverse $ take 2 $ Map.toAscList gt of
            (k, _) : _ -> setPosition k
            []         -> return ()
        loopPlaying
      ButtonWheelUp -> do
        pos <- gets vPosition
        lns <- gets $ vLines . vTracks
        case Map.splitLookup pos lns of
          (lt, _, _) -> case reverse $ take 3 $ Map.toDescList lt of
            (k, _) : _ -> setPosition k
            []         -> return ()
        loopPlaying
      _ -> loopPlaying
    _ -> loopPlaying

allSources :: Prog [Source]
allSources = do
  (dl, dr) <- gets $ vDrumAudio . vSources
  (sl, sr) <- gets $ vSongAudio . vSources
  return [dl, dr, sl, sr]

pauseAll, playAll :: Prog ()
pauseAll = allSources >>= liftIO . pause
playAll  = allSources >>= liftIO . play

-- | Uses an audio source (or SDL's timer) to bump our position forward.
-- Also triggers metronome sounds, if we passed a bar line.
updatePlaying :: Prog ()
updatePlaying = do
  posOld <- gets vPosition
  lns <- gets $ vLines . vTracks
  srcs <- allSources
  secNew <- case srcs of
    -- If there is an audio source: get our current position by copying the
    -- source's position. TODO: make sure the audio hasn't ended?
    src : _ -> do
      t <- liftIO $ ALUT.get $ secOffset src
      a <- gets $ vAudioStart . vSources
      return $ max 0 $ realToFrac $ t - a
    -- If there is no audio source: TODO: get our current position by finding
    -- the difference in SDL ticks from the place where we last recorded a
    -- ticks/position pair.
    []      -> undefined
  posNew <- positionBoth $ Seconds secNew
  modify $ \prog -> prog { vPosition = posNew }
  met <- gets vMetronome
  -- Search the space in [posOld, posNew) for a Measure/Beat line.
  -- If so, trigger a metronome sound if the metronome is on.
  when (posNew > posOld && met) $ case Map.splitLookup posOld lns of
    (_, eq, gt) -> case Map.splitLookup posNew gt of
      (lt, _, _) -> let
        search = maybe id (:) eq $ Map.elems lt
        in when (any (`elem` [Measure, Beat]) search) $ do
          clk <- gets $ vClick . vSources
          liftIO $ stop [clk]
          liftIO $ secOffset clk $= 0
          liftIO $ play [clk]

trackToMap :: F.Tempo -> RTB.T F.ElapsedTime a -> Map.Map Beats [a]
trackToMap res = let res' = fromIntegral res
  in Map.mapKeysMonotonic (\tks -> fromIntegral tks / res')
  . Map.fromDistinctAscList . ATB.toPairList . RTB.toAbsoluteEventList 0
  . RTB.collectCoincident

trackName :: Map.Map Beats [E.T] -> Maybe String
trackName trk = Map.lookup 0 trk >>= listToMaybe . mapMaybe isName where
  isName :: E.T -> Maybe String
  isName (E.MetaEvent (M.TrackName str)) = Just str
  isName _                               = Nothing

midiDrums :: Map.Map Beats [E.T] -> Prog ()
midiDrums trk = let
  pitchToNote (c, p, v) = case V.fromPitch p of
    35 -> Just $ Kick hit -- acoustic bass drum
    36 -> Just $ Kick hit -- bass drum 1
    38 -> Just $ Snare hit -- acoustic snare
    40 -> Just SnareFlam -- electric snare
    41 -> Just $ Tom (fromMaybe Green ybg) hit
    42 -> Just $ HihatC $ fromMaybe Yellow ybg
    43 -> Just $ Tom (fromMaybe Green ybg) hit
    44 -> Just HihatF
    45 -> Just $ Tom (fromMaybe Blue ybg) hit
    46 -> Just $ HihatO $ fromMaybe Yellow ybg
    47 -> Just $ Tom (fromMaybe Blue ybg) hit
    48 -> Just $ Tom (fromMaybe Yellow ybg) hit
    49 -> Just $ Crash $ fromMaybe Green ybg -- crash 1
    50 -> Just $ Tom (fromMaybe Yellow ybg) hit
    51 -> Just $ Ride $ fromMaybe Blue ybg -- ride 1
    52 -> Just $ Crash $ fromMaybe Yellow ybg -- china
    53 -> Just $ Ride $ fromMaybe Blue ybg -- ride bell
    55 -> Just $ Crash $ fromMaybe Yellow ybg -- splash
    57 -> Just $ Crash $ fromMaybe Blue ybg -- crash 2
    59 -> Just $ Ride $ fromMaybe Green ybg -- ride 2
    _ -> Nothing
    where ybg = case C.fromChannel c of
            1 -> Just Yellow
            2 -> Just Blue
            3 -> Just Green
            _ -> Nothing
          hit = if V.fromVelocity v >= 64 then Normal else Ghost
  getNoteOn e = case e of
    E.MIDIEvent (C.Cons c (C.Voice (V.NoteOn p v)))
      | V.fromVelocity v /= 0 -> Just (c, p, v)
    _                         -> Nothing
  listToSet es = let
    st = Set.fromList $ mapMaybe (getNoteOn >=> pitchToNote) es
    in guard (not $ Set.null st) >> Just st
  in loadDrums $ Map.mapMaybe listToSet trk

loadDrums :: Map.Map Beats (Set.Set Note) -> Prog ()
loadDrums drms = do
  tmps <- gets $ vTempos . vTracks
  let drms' = positionTrack tmps drms
  modify $ \prog -> prog { vTracks = (vTracks prog) { vDrums = drms' } }

midiTempos :: Map.Map Beats [E.T] -> Prog ()
midiTempos trk = let
  getTempo e = case e of
    -- (1000000 microsec/sec) / (x microsec/beat) = (1000000 / x) (beat/sec)
    E.MetaEvent (M.SetTempo mspb) -> Just $ 1000000 / realToFrac mspb
    _                             -> Nothing
  in loadTempos $ Map.mapMaybe (listToMaybe . mapMaybe getTempo) trk

loadTempos :: Map.Map Beats BPS -> Prog ()
loadTempos tmps = let
  tmps' = positionTempos tmps
  toBoth pos = let bts = toBeats pos in Both (beatsToSeconds' tmps' bts) bts
  in modify $ \prog -> let
    trks = vTracks prog
    in prog
      { vPosition = toBoth $ vPosition prog
      , vEnd      = toBoth $ vEnd prog
      , vTracks   = trks
        { vTempos   = tmps'
        , vDrums    = Map.mapKeysMonotonic toBoth $ vDrums trks
        , vTimeSigs = Map.mapKeysMonotonic toBoth $ vTimeSigs trks
        , vLines    = Map.mapKeysMonotonic toBoth $ vLines trks
        }
      }

midiTimeSigs :: Map.Map Beats [E.T] -> Prog ()
midiTimeSigs trk = let
  getTimeSig e = case e of
    E.MetaEvent (M.TimeSig n d _ _) -> Just (n, (2 ^^ (-d)) * 4)
    _                               -> Nothing
  in loadTimeSigs $ Map.mapMaybe (listToMaybe . mapMaybe getTimeSig) trk

loadTimeSigs :: Map.Map Beats (Int, Beats) -> Prog ()
loadTimeSigs sigs = do
  tmps <- gets $ vTempos . vTracks
  let sigs' = positionTrack tmps sigs
  modify $ \prog -> prog { vTracks = (vTracks prog) { vTimeSigs = sigs' } }
  makeLines

loadMIDI :: F.T -> Prog ()
loadMIDI f = case f of
  F.Cons F.Parallel (F.Ticks res) trks -> let
    beatTrks = map (trackToMap res) trks
    trkNames = map trackName beatTrks
    drumTrk  = lookup (Just "onyx_drums") $ zip trkNames beatTrks
    firstTrk = listToMaybe beatTrks
    lastPos  = maximum $ 0 : map trkLast beatTrks
    trkLast trk = case Map.maxViewWithKey trk of
      Just ((k, _), _) -> k
      Nothing          -> 0
    in do
      clearAll
      end <- positionBoth $ Beats $ lastPos + 4
      modify $ \prog -> prog { vEnd = end }
      maybe (return ()) midiTempos firstTrk
      maybe (return ()) midiTimeSigs firstTrk
      maybe (return ()) midiDrums drumTrk
      setPosition $ Both 0 0
  _ -> error "loadMIDI: Not a parallel ticks-based MIDI file"

emptyTracks :: Tracks
emptyTracks = Tracks
  { vTempos   = Map.singleton (Both 0 0) 2
  , vDrums    = Map.empty
  , vTimeSigs = Map.singleton (Both 0 0) (4, 1)
  , vLines    = Map.empty
  }

clearAll :: Prog ()
clearAll = modify $ \prog -> prog
  { vTracks   = emptyTracks
  , vPosition = Both 0 0
  , vEnd      = Both 0 0
  }

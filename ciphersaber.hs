{-# LANGUAGE BangPatterns #-}
import Control.Monad
import Data.Array.IO
import qualified Data.Bits as B
import qualified Data.ByteString.Lazy as BS
import Data.Char
import Data.Word
import System.Console.ParseArgs
import System.IO

data ArgInd = ArgEncrypt | ArgDecrypt | ArgKey
     deriving (Ord, Eq, Show)

argd :: [ Arg ArgInd ]
argd = [
  Arg {
     argIndex = ArgEncrypt,
     argName = Just "encrypt",
     argAbbr = Just 'e',
     argData = Nothing,
     argDesc = "Use decryption mode."
  },
  Arg {
     argIndex = ArgDecrypt,
     argName = Just "decrypt",
     argAbbr = Just 'd',
     argData = Nothing,
     argDesc = "Use encryption mode."
  },
  Arg {
     argIndex = ArgKey,
     argName = Nothing,
     argAbbr = Nothing,
     argData = argDataRequired "key" ArgtypeString,
     argDesc = "Encryption or decryption key."
  } ]

type CState = IOUArray Word8 Word8

fi :: (Integral a, Num b) => a -> b
fi = fromIntegral

initKeystream :: String -> [Word8] -> IO CState
initKeystream key iv = do
  let kl = cycle $ map (fi . ord) key ++ iv
  state <- newListArray (0, 255) [0..255]
  mixArray kl state (0, 0)
  where
    mixArray :: [Word8] -> CState -> (Int, Word8) -> IO CState
    mixArray k a (i, j) | i < 256 = do
      si <- readArray a (fi i)
      let j' = j + fi si + fi (k !! i)
      sj' <- readArray a j'
      writeArray a (fi i) sj'
      writeArray a j' si
      mixArray k a (i + 1, j')
    mixArray _ a _ = return a

readIV :: IO [Word8]
readIV = do
  ivs <- BS.hGet stdin 10
  let ivl = BS.unpack ivs
  return ivl

makeIV :: IO [Word8]
makeIV = 
  withBinaryFile "/dev/urandom" ReadMode $ \h ->
  do
    hSetBuffering h NoBuffering
    ivs <- BS.hGet h 10
    BS.hPut stdout ivs
    return $ BS.unpack ivs

accumMapM :: Monad m => (a -> b -> m (a, b)) -> a -> [b] -> m [b]
accumMapM _ _ [] = return []
accumMapM a acc (b : bs) = do
  (acc', b') <- a acc b
  accumMapM a acc' bs >>= return . (b' :)

type Accum = ((Word8, Word8), CState)

stepRC4 :: Accum -> Word8 -> IO (Accum, Word8)
stepRC4 ((i, j), state) b = do
  let i' = i + 1
  si' <- readArray state i'
  let j' = j + si'
  sj' <- readArray state j'
  writeArray state i' sj'
  writeArray state j' si'
  k <- readArray state (si' + sj')
  return (((i', j'), state), k `B.xor` b)

applyKeystream :: CState -> [Word8] -> IO [Word8]
applyKeystream state intext = 
  accumMapM stepRC4 ((0, 0), state) intext

applyStreamCipher :: CState -> IO ()
applyStreamCipher state = do
  intext <- BS.getContents
  outtext <- applyKeystream state $ BS.unpack intext
  BS.putStr $ BS.pack outtext

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  argv <- parseArgsIO ArgsComplete argd
  let k = getRequiredArg argv ArgKey
  let e = gotArg argv ArgEncrypt
  let d = gotArg argv ArgDecrypt
  unless ((e && not d) || (d && not e)) $
    usageError argv "Exactly one of -e or -d is required."
  iv <- if e then makeIV else readIV
  s <- initKeystream k iv
  applyStreamCipher s

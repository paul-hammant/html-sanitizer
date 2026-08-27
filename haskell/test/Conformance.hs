{-# LANGUAGE OverloadedStrings #-}

-- |
-- The 12-check binding conformance suite (@docs\/conformance.md@).
--
-- Proves the Haskell binding marshals every value shape across the FFI. It is
-- __not__ a sanitizer test suite — the behavioural cases live in the engine's
-- own tests and run once, in Aether.
--
-- == Why a plain runner and not hspec\/tasty
--
-- hspec and tasty arrive from Hackage, so running them needs a @cabal update@
-- and a network round trip (or a pre-warmed store) before a single assertion
-- executes. The rest of this monorepo's bindings test with whatever is already
-- on the box — @php tests\/conformance.php@, a .NET console runner — so this one
-- does too. The dependency set is @base@ + @bytestring@, both of which ship
-- with GHC, which means @runghc@ can drive the whole suite offline:
--
-- @
--     runghc -isrc -itest test\/Conformance.hs
-- @
--
-- The trade is real and small: no test discovery, no @--match@, no shrinking.
-- For thirty-odd marshalling assertions that costs nothing, and it keeps the
-- binding testable on an air-gapped machine. Swapping in hspec later is
-- mechanical — each @check@ below is one @it@.
--
-- The process exit code is the result: 0 all-pass, 1 any failure.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (sort)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hSetEncoding, stdout, utf8)

import HtmlSanitizer
import qualified HtmlSanitizer.Native as N

-- ---------------------------------------------------------------------------
-- A minimal assertion runner
-- ---------------------------------------------------------------------------

-- Failures are accumulated rather than fatal, so one broken marshalling path
-- does not hide the other eleven.
type Failures = IORef [String]

-- | An assertion failure, raised inside a check body and caught by 'check'.
--
-- 'ioError' . 'userError' rather than 'error': it throws an ordinary
-- 'IOException' from 'IO' rather than an imprecise exception from pure code,
-- so it is raised exactly where it is written (no laziness surprises about
-- when a failure actually surfaces) and 'show' renders it without a call
-- stack. Both are in the Prelude, so it costs no import.
assertFail :: String -> IO a
assertFail = ioError . userError

-- | Run one check with a freshly-created sanitizer, so each starts from the
-- engine's defaults, and close it afterwards even if the body throws.
check :: Failures -> String -> (Sanitizer -> IO ()) -> IO ()
check fs name body = checkIO fs name (withSanitizer body)

-- | Run one check that manages its own sanitizer(s).
checkIO :: Failures -> String -> IO () -> IO ()
checkIO fs name body = do
  r <- try body :: IO (Either SomeException ())
  case r of
    Right () -> putStrLn ("  PASS " ++ name)
    Left e -> do
      modifyIORef' fs (++ [name ++ ": " ++ show e])
      putStrLn ("  FAIL " ++ name)
      putStrLn ("       " ++ show e)

eqStr :: String -> B.ByteString -> B.ByteString -> IO ()
eqStr what got want =
  unless (got == want) $
    assertFail $
      what
        ++ ":\n         got  \""
        ++ render got
        ++ "\"\n         want \""
        ++ render want
        ++ "\""

-- | Render a ByteString for a failure message.
--
-- 'C.unpack' maps each BYTE to a Char 0..255, so a UTF-8 payload printed
-- through the UTF-8 handle we set in 'main' would come out as mojibake — the
-- bytes get re-encoded a second time. For a diagnostic that is worse than
-- useless when check 4 is the one failing, so any non-ASCII byte switches the
-- whole string to an explicit hex dump.
render :: B.ByteString -> String
render bs
  | B.all (< 0x80) bs = C.unpack bs
  | otherwise = unwords (map hex2 (B.unpack bs))
  where
    digits = "0123456789abcdef"
    hex2 w =
      let n = fromIntegral w :: Int
       in [digits !! (n `div` 16), digits !! (n `mod` 16)]

eqInt :: String -> Int -> Int -> IO ()
eqInt what got want =
  unless (got == want) $
    assertFail (what ++ ": got " ++ show got ++ ", want " ++ show want)

isTrue :: String -> Bool -> IO ()
isTrue what got = unless got $ assertFail (what ++ ": expected True")

isFalse :: String -> Bool -> IO ()
isFalse what got = when got $ assertFail (what ++ ": expected False")

containsElem :: (Eq a, Show a) => String -> [a] -> a -> IO ()
containsElem what haystack needle =
  unless (needle `elem` haystack) $
    assertFail (what ++ ": " ++ show needle ++ " not found in " ++ show haystack)

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  -- Check 4 prints non-ASCII on failure; without this the handle's encoding
  -- follows the locale and a C-locale CI box dies with "invalid character"
  -- while REPORTING a failure, which is a maddening way to lose a diagnostic.
  hSetEncoding stdout utf8
  putStrLn "=== htmlsanitizer Haskell binding conformance ==="
  v <- abiVersion
  putStrLn ("engine: ABI v" ++ show v)

  fs <- newIORef []
  runChecks fs
  failures <- readIORef fs

  putStrLn ("=== " ++ show (length failures) ++ " failed ===")
  if null failures
    then exitSuccess
    else do
      putStrLn "failures:"
      forM_ failures (\f -> putStrLn ("  - " ++ f))
      exitFailure

runChecks :: Failures -> IO ()
runChecks fs = do
  -- ---- the twelve ----

  check fs "01 script removed" $ \s -> do
    out <- sanitize s "<div>Hello <script>alert(1)</script> world!</div>"
    eqStr "output" out "<div>Hello  world!</div>"

  check fs "02 onclick removed" $ \s -> do
    out <- sanitize s "<div onclick=\"alert(1)\">Hello</div>"
    eqStr "output" out "<div>Hello</div>"

  check fs "03 empty string" $ \s -> do
    -- The classic NULL-vs-"" bug: a binding that maps a null char* to an
    -- error, or that returns a garbage pointer for the empty result.
    out <- sanitize s ""
    eqStr "output" out ""

  check fs "04 utf-8 round trip" $ \s -> do
    -- These are UTF-8 byte literals via OverloadedStrings on ByteString,
    -- which takes the low 8 bits of each Char — so we spell the multibyte
    -- sequences explicitly rather than trusting the literal.
    let cafe = B.concat ["<div>caf", B.pack [0xc3, 0xa9], " ", B.pack [0xe2, 0x98, 0x95], "</div>"]
    out <- sanitize s cafe
    eqStr "output" out cafe

  check fs "05 allow custom tag" $ \s -> do
    before <- sanitize s "<my-widget>x</my-widget>"
    eqStr "before" before ""
    ok <- allow s Tags "my-widget"
    isTrue "allow returned True" ok
    after <- sanitize s "<my-widget>x</my-widget>"
    eqStr "after" after "<my-widget>x</my-widget>"

  check fs "06 disallow tag" $ \s -> do
    before <- sanitize s "<div>x</div>"
    eqStr "before" before "<div>x</div>"
    ok <- disallow s Tags "div"
    isTrue "disallow returned True" ok
    after <- sanitize s "<div>x</div>"
    eqStr "after" after ""

  check fs "07 membership and count" $ \s -> do
    http <- isAllowed s Schemes "http"
    isTrue "http allowed" http
    gopher <- isAllowed s Schemes "gopher"
    isFalse "gopher allowed" gopher
    n <- countList s Schemes
    eqInt "scheme count" n 2

  check fs "08 enumeration" $ \s -> do
    got <- sortedItems s Schemes
    eqInt "enumerated count" (length got) 2
    isTrue "sorted == [http, https]" (got == ["http", "https"])

  check fs "09 keep child nodes" $ \s -> do
    before <- sanitize s "<div><nope>Hello <span>world</span></nope></div>"
    eqStr "before" before "<div></div>"
    setKeepChildNodes s True
    flag <- getKeepChildNodes s
    isTrue "keepChildNodes reads back True" flag
    after <- sanitize s "<div><nope>Hello <span>world</span></nope></div>"
    eqStr "after" after "<div>Hello <span>world</span></div>"

  -- Check 10 and 11 are the ones worth being careful about — the callback
  -- trampoline and the string-returning hook. Haskell expresses both natively
  -- via `foreign import ccall "wrapper"`, so this binding skips neither.

  check fs "10 onRemovingTag cancels" $ \s -> do
    seen <- newIORef ([] :: [(B.ByteString, N.Reason)])
    onRemovingTag s $ Just $ \node reason -> do
      name <- nodeName node
      modifyIORef' seen (++ [(name, reason)])
      pure (name == "keep-me")
    out <- sanitize s "<div><keep-me>a</keep-me><drop-me>b</drop-me></div>"
    eqStr "output" out "<div><keep-me>a</keep-me></div>"
    got <- readIORef seen
    containsElem "hook saw keep-me" (map fst got) "keep-me"
    containsElem "hook saw drop-me" (map fst got) "drop-me"
    -- An int/long width mismatch in the callback signature shows up here as a
    -- garbage reason rather than NotAllowedTag.
    containsElem "reason is a real int" (map snd got) N.NotAllowedTag

  check fs "11 onFilterUrl rewrites" $ \s -> do
    onFilterUrl s $ Just $ \_elem _raw resolved ->
      pure $
        if resolved == "https://example.com/logo.png"
          then "https://cdn.example.net/logo.png"
          else resolved
    out <- sanitizeWithBase s "<img src=\"logo.png\">" "https://example.com"
    eqStr "output" out "<img src=\"https://cdn.example.net/logo.png\">"

  checkIO fs "12 handles are independent" $
    withSanitizer $ \a -> withSanitizer $ \b -> do
      _ <- allow a Tags "only-in-a"
      inA <- isAllowed a Tags "only-in-a"
      inB <- isAllowed b Tags "only-in-a"
      isTrue "a knows the tag" inA
      isFalse "b does not" inB

  -- ---- a few extras that exercise the remaining callback shapes ----

  check fs "onRemovingAttribute sees the attribute" $ \s -> do
    seen <- newIORef ([] :: [B.ByteString])
    onRemovingAttribute s $ Just $ \el attr _reason -> do
      en <- nodeName el
      an <- attrName attr
      av <- attrValue attr
      modifyIORef' seen (++ [B.intercalate "/" [en, an, av]])
      pure False -- False = proceed with the removal
    out <- sanitize s "<div onclick=\"alert(1)\">x</div>"
    eqStr "output" out "<div>x</div>"
    got <- readIORef seen
    containsElem "attribute hook" got "div/onclick/alert(1)"

  check fs "onRemovingComment cancels" $ \s -> do
    onRemovingComment s $ Just $ \_node -> pure True
    out <- sanitize s "<div>a<!-- keep -->b</div>"
    eqStr "output" out "<div>a<!-- keep -->b</div>"

  check fs "onRemovingStyle is four-arg" $ \s -> do
    seen <- newIORef ([] :: [(B.ByteString, B.ByteString)])
    onRemovingStyle s $ Just $ \_el name value _reason -> do
      modifyIORef' seen (++ [(name, value)])
      pure (name == "-custom-thing")
    out <- sanitize s "<div style=\"-custom-thing: 3; color: red\">x</div>"
    isTrue "custom property kept" ("-custom-thing" `B.isInfixOf` out)
    got <- readIORef seen
    containsElem "style hook args" got ("-custom-thing", "3")

  check fs "onPostProcessNode visits" $ \s -> do
    kinds <- newIORef ([] :: [N.NodeKind])
    onPostProcessNode s $ Just $ \node -> do
      k <- nodeKind node
      modifyIORef' kinds (++ [k])
    _ <- sanitize s "<div><span>a</span><span>b</span></div>"
    got <- readIORef kinds
    isTrue "onPostProcessNode fired" (not (null got))

  check fs "node tree navigation" $ \s -> do
    kindRef <- newIORef (N.UnknownKind 0)
    childRef <- newIORef (0 :: Int)
    parentOk <- newIORef False
    onPostProcessDom s $ Just $ \doc -> do
      k <- nodeKind doc
      writeIORef kindRef k
      kids <- nodeChildren doc
      writeIORef childRef (length kids)
      case kids of
        (first : _) -> do
          p <- nodeParent first
          writeIORef parentOk (maybe False (const True) p)
        [] -> pure ()
    _ <- sanitize s "<div>a</div><p>b</p>"
    k <- readIORef kindRef
    isTrue "document kind" (k == N.Document)
    n <- readIORef childRef
    isTrue "document has >= 2 children" (n >= 2)
    po <- readIORef parentOk
    isTrue "child's parent is set" po

  check fs "setAttrValue rewrites an attribute in place" $ \s -> do
    onRemovingAttribute s $ Just $ \_el attr _reason -> do
      an <- attrName attr
      when (an == "onclick") $ do
        setAttrValue attr "sanitised"
        v <- attrValue attr
        eqStr "value after setAttrValue" v "sanitised"
      pure False
    out <- sanitize s "<div onclick=\"alert(1)\">x</div>"
    eqStr "output" out "<div>x</div>"

  check fs "attribute enumeration" $ \s -> do
    names <- newIORef ([] :: [B.ByteString])
    onPostProcessNode s $ Just $ \node -> do
      k <- nodeKind node
      nm <- nodeName node
      when (k == N.Element && nm == "a") $ do
        attrs <- nodeAttributes node
        forM_ attrs $ \a -> do
          an <- attrName a
          modifyIORef' names (++ [an])
    _ <- sanitize s "<a href=\"https://example.com/\" title=\"t\">x</a>"
    got <- readIORef names
    containsElem "href seen" got "href"
    containsElem "title seen" got "title"

  check fs "clearing a hook restores default behaviour" $ \s -> do
    onRemovingTag s $ Just $ \node _r -> (== "keep-me") <$> nodeName node
    kept <- sanitize s "<div><keep-me>a</keep-me></div>"
    eqStr "with hook" kept "<div><keep-me>a</keep-me></div>"
    onRemovingTag s Nothing
    dropped <- sanitize s "<div><keep-me>a</keep-me></div>"
    eqStr "hook cleared" dropped "<div></div>"

  check fs "re-registering a hook does not crash or double-free" $ \s -> do
    -- Each registration mints a new FunPtr stub; the superseded ones stay
    -- retained until close. If the binding freed the old stub eagerly, the
    -- engine's next call would jump through reclaimed memory — which shows up
    -- here as a segfault, not a failed assertion.
    onRemovingTag s $ Just $ \node _r -> (== "keep-me") <$> nodeName node
    onRemovingTag s $ Just $ \node _r -> (== "keep-me") <$> nodeName node
    out <- sanitize s "<div><keep-me>a</keep-me></div>"
    eqStr "second registration wins" out "<div><keep-me>a</keep-me></div>"
    clearHooks s
    after <- sanitize s "<div><keep-me>a</keep-me></div>"
    eqStr "clearHooks cleared it" after "<div></div>"

  check fs "sanitizeDocument is wired" $ \s -> do
    out <- sanitizeDocument s "<div>doc<script>x</script></div>"
    eqStr "output" out "<html><head></head><body><div>doc</div></body></html>"

  check fs "allowDataAttributes flag" $ \s -> do
    off <- getAllowDataAttributes s
    isFalse "off by default" off
    setAllowDataAttributes s True
    on <- getAllowDataAttributes s
    isTrue "on after set" on
    out <- sanitize s "<div data-x=\"1\"></div>"
    eqStr "output" out "<div data-x=\"1\"></div>"

  check fs "clear empties a policy list" $ \s -> do
    ok <- clearList s Schemes
    isTrue "clear returned True" ok
    n <- countList s Schemes
    eqInt "count after clear" n 0

  check fs "item at an out-of-range index is empty" $ \s -> do
    oob <- itemAt s Schemes 999
    eqStr "out of range" oob ""
    neg <- itemAt s Schemes (-1)
    eqStr "negative index" neg ""

  check fs "every policy list is reachable" $ \s -> do
    -- Proves the `which` selector constants line up with the engine's, in all
    -- six positions — an off-by-one here would silently edit the wrong list.
    forM_ [minBound .. maxBound :: Which] $ \w -> do
      _ <- allow s w "probe-item"
      hit <- isAllowed s w "probe-item"
      isTrue ("selector " ++ show w ++ " round-trips") hit

  check fs "items enumerates in the engine's own order" $ \s -> do
    raw <- items s Schemes
    eqInt "raw count" (length raw) 2
    isTrue "sorting it gives [http, https]" (sort raw == ["http", "https"])

  check fs "ABI version" $ \_s -> do
    v <- abiVersion
    isTrue "abiVersion >= 1" (v >= 1)

  checkIO fs "closed sanitizer rejects use" $ do
    s <- new
    close s
    closed <- isClosed s
    isTrue "isClosed after close" closed
    r <- try (sanitize s "<div>x</div>") :: IO (Either SomeException B.ByteString)
    case r of
      Left _ -> pure ()
      Right _ -> assertFail "expected an exception from a closed sanitizer"
    close s -- idempotent

  checkIO fs "many sanitize calls do not leak or crash" $
    withSanitizer $ \s -> do
      -- A returned char* that was never freed would show up here as steadily
      -- growing RSS; a double free would crash. Cheap insurance over the
      -- takeString contract, and it also exercises a registered hook being
      -- entered thousands of times from a `safe` foreign call.
      onPostProcessNode s $ Just $ \_node -> pure ()
      let payload =
            B.concat
              ["<div onclick=\"x\">caf", B.pack [0xc3, 0xa9], " <script>no</script></div>"]
      forM_ [1 :: Int .. 5000] $ \_ -> sanitize s payload
      out <- sanitize s "<div>ok</div>"
      eqStr "still working" out "<div>ok</div>"

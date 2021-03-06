{-# LANGUAGE MultiParamTypeClasses, GeneralizedNewtypeDeriving, DeriveDataTypeable, ScopedTypeVariables #-}

module Development.Shake.Rules.File(
    need, needBS, needed, neededBS, want,
    trackRead, trackWrite, trackAllow,
    defaultRuleFile,
    (*>), (**>), (?>), phony, (~>)
    ) where

import Control.Monad
import Control.Monad.IO.Class
import System.Directory
import qualified Data.ByteString.Char8 as BS

import Development.Shake.Core hiding (trackAllow)
import qualified Development.Shake.Core as S
import General.String
import Development.Shake.Classes
import Development.Shake.FilePattern
import Development.Shake.FileTime
import Development.Shake.Types
import Development.Shake.Errors

import Data.List
import Data.Maybe
import System.FilePath(takeDirectory) -- important that this is the system local filepath, or wrong slashes go wrong


infix 1 *>, ?>, **>, ~>


newtype FileQ = FileQ BSU
    deriving (Typeable,Eq,Hashable,Binary,NFData)

instance Show FileQ where show (FileQ x) = unpackU x

newtype FileA = FileA FileTime
    deriving (Typeable,Hashable,Binary,NFData)

instance Eq FileA where FileA x == FileA y = x /= fileTimeNone && x == y

instance Show FileA where show (FileA x) = "FileTimeHash " ++ show x

instance Rule FileQ FileA where
    storedValue _ (FileQ x) = fmap (fmap FileA) $ getModTimeMaybe x


-- | This function is not actually exported, but Haddock is buggy. Please ignore.
defaultRuleFile :: Rules ()
defaultRuleFile = priority 0 $ rule $ \(FileQ x) -> Just $
    liftIO $ fmap FileA $ getModTimeError "Error, file does not exist and no rule available:" x


-- | Add a dependency on the file arguments, ensuring they are built before continuing.
--   The file arguments may be built in parallel, in any order. This function is particularly
--   necessary when calling 'Development.Shake.cmd' or 'Development.Shake.command'. As an example:
--
-- @
-- \"\/\/*.rot13\" '*>' \\out -> do
--     let src = 'Development.Shake.FilePath.dropExtension' out
--     'need' [src]
--     'Development.Shake.cmd' \"rot13\" [src] \"-o\" [out]
-- @
--
--   Usually @need [foo,bar]@ is preferable to @need [foo] >> need [bar]@ as the former allows greater
--   parallelism, while the latter requires @foo@ to finish building before starting to build @bar@.
need :: [FilePath] -> Action ()
need xs = (apply $ map (FileQ . packU) xs :: Action [FileA]) >> return ()

needBS :: [BS.ByteString] -> Action ()
needBS xs = (apply $ map (FileQ . packU_) xs :: Action [FileA]) >> return ()


-- | Like 'need', but if 'shakeLint' is set, check that the file does not rebuild.
--   Used for adding dependencies on files that have already been used in this rule.
needed :: [FilePath] -> Action ()
needed xs = do
    opts <- getShakeOptions
    if isNothing $ shakeLint opts then need xs else neededCheck $ map packU xs


neededBS :: [BS.ByteString] -> Action ()
neededBS xs = do
    opts <- getShakeOptions
    if isNothing $ shakeLint opts then needBS xs else neededCheck $ map packU_ xs


neededCheck :: [BSU] -> Action ()
neededCheck xs = do
    pre <- liftIO $ mapM getModTimeMaybe xs
    post <- apply $ map FileQ xs :: Action [FileA]
    let bad = [ (x, if isJust a then "File change" else "File created")
              | (x, a, FileA b) <- zip3 xs pre post, Just b /= a]
    case bad of
        [] -> return ()
        (file,msg):_ -> errorStructured
            "Lint checking error - 'needed' file required rebuilding"
            [("File", Just $ unpackU file)
            ,("Error",Just msg)]
            ""


-- | Track that a file was read by the action preceeding it. If 'shakeLint' is activated
--   then these files must be dependencies of this rule. Calls to 'trackRead' are
--   automatically inserted in 'LintTracker' mode.
trackRead :: [FilePath] -> Action ()
trackRead = mapM_ (trackUse . FileQ . packU)

-- | Track that a file was written by the action preceeding it. If 'shakeLint' is activated
--   then these files must either be the target of this rule, or never referred to by the build system.
--   Calls to 'trackWrite' are automatically inserted in 'LintTracker' mode.
trackWrite :: [FilePath] -> Action ()
trackWrite = mapM_ (trackChange . FileQ . packU)

-- | Allow accessing a file in this rule, ignoring any 'trackRead'\/'trackWrite' calls matching
--   the pattern.
trackAllow :: [FilePattern] -> Action ()
trackAllow ps = do
    opts <- getShakeOptions
    when (isJust $ shakeLint opts) $
        S.trackAllow $ \(FileQ x) -> any (?== unpackU x) ps


-- | Require that the argument files are built by the rules, used to specify the target.
--
-- @
-- main = 'Development.Shake.shake' 'shakeOptions' $ do
--    'want' [\"Main.exe\"]
--    ...
-- @
--
--   This program will build @Main.exe@, given sufficient rules. All arguments to all 'want' calls
--   may be built in parallel, in any order.
--
--   This function is defined in terms of 'action' and 'need', use 'action' if you need more complex
--   targets than 'want' allows.
want :: [FilePath] -> Rules ()
want = action . need


root :: String -> (FilePath -> Bool) -> (FilePath -> Action ()) -> Rules ()
root help test act = rule $ \(FileQ x_) -> let x = unpackU x_ in
    if not $ test x then Nothing else Just $ do
        liftIO $ createDirectoryIfMissing True $ takeDirectory x
        act x
        liftIO $ fmap FileA $ getModTimeError ("Error, rule " ++ help ++ " failed to build file:") x_


-- | Declare a phony action -- an action that does not produce a file, and will be rerun
--   in every execution that requires it. You can demand 'phony' rules using 'want' \/ 'need'.
--   Phony actions are never executed more than once in a single build run.
--
--   Phony actions are intended to define command-line abbreviations. If you 'need' a phony action
--   in a rule then every execution where that rule is required will rerun both the rule and the phony
--   action.
phony :: String -> Action () -> Rules ()
phony name act = rule $ \(FileQ x_) -> let x = unpackU x_ in
    if name /= x then Nothing else Just $ do
        act
        return $ FileA fileTimeNone

-- | Infix operator alias for 'phony', for sake of consistency with normal
--   rules.
(~>) :: String -> Action () -> Rules ()
(~>) = phony 


-- | Define a rule to build files. If the first argument returns 'True' for a given file,
--   the second argument will be used to build it. Usually '*>' is sufficient, but '?>' gives
--   additional power. For any file used by the build system, only one rule should return 'True'.
--   This function will create the directory for the result file, if necessary.
--
-- @
-- (all isUpper . 'Development.Shake.FilePath.takeBaseName') '?>' \\out -> do
--     let src = 'Development.Shake.FilePath.replaceBaseName' out $ map toLower $ takeBaseName out
--     'Development.Shake.writeFile'' out . map toUpper =<< 'Development.Shake.readFile'' src
-- @
(?>) :: (FilePath -> Bool) -> (FilePath -> Action ()) -> Rules ()
(?>) test act = priority 0.5 $ root "with ?>" test act


-- | Define a set of patterns, and if any of them match, run the associated rule. See '*>'.
(**>) :: [FilePattern] -> (FilePath -> Action ()) -> Rules ()
-- Should probably have been called |*>, since it's an or (||) of *>
(**>) pats act = let (simp,other) = partition simple pats in f simp >> priority 0.5 (f other)
    where f ps = let ps2 = map (?==) ps in unless (null ps2) $ root "with **>" (\x -> any ($ x) ps2) act

-- | Define a rule that matches a 'FilePattern'. No file required by the system must be
--   matched by more than one pattern. For the pattern rules, see '?=='.
--   This function will create the directory for the result file, if necessary.
--
-- @
-- \"*.asm.o\" '*>' \\out -> do
--     let src = 'Development.Shake.FilePath.dropExtension' out
--     'need' [src]
--     'Development.Shake.cmd' \"as\" [src] \"-o\" [out]
-- @
--
--   To define a build system for multiple compiled languages, we recommend using @.asm.o@,
--   @.cpp.o@, @.hs.o@, to indicate which language produces an object file.
--   I.e., the file @foo.cpp@ produces object file @foo.cpp.o@.
--
--   Note that matching is case-sensitive, even on Windows.
(*>) :: FilePattern -> (FilePath -> Action ()) -> Rules ()
(*>) test act = (if simple test then id else priority 0.5) $ root (show test) (test ?==) act

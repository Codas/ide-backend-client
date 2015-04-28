{-# LANGUAGE NamedFieldPuns #-}
module Main where

import Control.Exception
import Control.Monad (join, mfilter)
import Control.Arrow ((***))
import Data.Function
import Data.List (sortBy)
import Data.Monoid
import Data.Ord
import Data.Text (Text)
import Prelude hiding (mod, span)
import System.IO

import qualified Data.Text as Text

import IdeSession
import IdeSession.Client.Cabal
import IdeSession.Client.CmdLine
import IdeSession.Client.JsonAPI
import IdeSession.Client.Util.ValueStream

main :: IO ()
main = do
  opts@Options{..} <- getCommandLineOptions
  case optCommand of
    ShowAPI ->
      putStrLn apiDocs
    StartEmptySession opts' -> do
      putEnc $ ResponseWelcome ideBackendClientVersion
      startEmptySession opts opts'
    StartCabalSession opts' -> do
      putEnc $ ResponseWelcome ideBackendClientVersion
      startCabalSession opts opts'
    ListTargets fp -> do
      putEnc $ ResponseWelcome ideBackendClientVersion
      putEnc =<< listTargets fp

startEmptySession :: Options -> EmptyOptions -> IO ()
startEmptySession Options{..} EmptyOptions =
    bracket (initSession optInitParams optConfig)
            shutdownSession
            mainLoop

startCabalSession :: Options -> CabalOptions -> IO ()
startCabalSession options cabalOptions = do
    bracket (initCabalSession options cabalOptions)
            shutdownSession
            mainLoop

-- | Version of the client API
--
-- This should be incremented whenever we make a change that editors might need
-- to know about.
ideBackendClientVersion :: VersionInfo
ideBackendClientVersion = VersionInfo 0 1 0

{-------------------------------------------------------------------------------
  Main loop

  Assumes the session has been properly initialized
-------------------------------------------------------------------------------}

type QuerySpanInfo = ModuleName -> SourceSpan -> [(SourceSpan, SpanInfo)]
type QueryExpInfo  = ModuleName -> SourceSpan -> [(SourceSpan, Text)]
type AutoCompInfo  = ModuleName -> String     -> [IdInfo]

mainLoop :: IdeSession -> IO ()
mainLoop session = do
    input <- newStream stdin
    updateSession session (updateCodeGeneration True) ignoreProgress
    spanInfo <- getSpanInfo session -- Might not be empty (for Cabal init)
    expTypes <- getExpTypes session
    autoComplete <- getAutocompletion session
    go input spanInfo expTypes autoComplete
  where
    -- Main loop
    --
    -- We pass spanInfo and expInfo as argument, which are updated after every
    -- session update (provided that there are no errors). This means that if
    -- the session updates fails we we will the info from the previous update.
    go :: Stream -> QuerySpanInfo -> QueryExpInfo -> AutoCompInfo -> IO ()
    go input spanInfo expTypes autoComplete = do
        value <- nextInStream input
        case fromJSON value of
          Left err -> do
            putEnc $ ResponseInvalidRequest err
            loop
          Right (RequestUpdateSession upd) -> do
            updateSession session (mconcat (map makeSessionUpdate upd)) $ \progress ->
              putEnc $ ResponseUpdateSession (Just progress)
            putEnc $ ResponseUpdateSession Nothing

            errors <- getSourceErrors session
            if all ((== KindWarning) . errorKind) errors
              then do
                spanInfo' <- getSpanInfo session
                expTypes' <- getExpTypes session
                autoComplete' <- getAutocompletion session
                go input spanInfo' expTypes' autoComplete'
              else do
                loop
          Right RequestGetSourceErrors -> do
            errors <- getSourceErrors session
            putEnc $ ResponseGetSourceErrors errors
            loop
          Right RequestGetLoadedModules -> do
            mods <- getLoadedModules session
            putEnc $ ResponseGetLoadedModules mods
            loop
          Right (RequestGetSpanInfo span) -> do
            fileMap <- getFileMap session
            case fileMap (spanFilePath span) of
              Just mod -> do
                let mkInfo (span', info) = ResponseSpanInfo info span'
                putEnc $ ResponseGetSpanInfo
                       $ map mkInfo
                       $ spanInfo (moduleName mod) span
              Nothing ->
                putEnc $ ResponseGetSpanInfo []
            loop
          Right (RequestGetExpTypes span) -> do
            fileMap <- getFileMap session
            case fileMap (spanFilePath span) of
              Just mod -> do
                let mkInfo (span', info) = ResponseExpType info span'
                putEnc $ ResponseGetExpTypes
                      $ map mkInfo
                      $ sortSpans
                      $ expTypes (moduleName mod) span
              Nothing ->
                putEnc $ ResponseGetExpTypes []
            loop
          Right (RequestGetAutocompletion autocmpletionSpan) -> do
            fileMap <- getFileMap session
            case fileMap (autocompletionFilePath autocmpletionSpan) of
              Just mod -> do
                let query = autocompletionPrefix autocmpletionSpan
                    splitQualifier = join (***) reverse . break (== '.') . reverse
                    (prefix, qualifierStr) = splitQualifier query
                    qualifier = mfilter (not . Text.null) (Just (Text.pack qualifierStr))
                putEnc $ ResponseGetAutocompletion
                       $ filter ((== qualifier) . autocompletionQualifier)
                       $ map idInfoToAutocompletion
                       $ autoComplete (moduleName mod) prefix
              Nothing ->
                putEnc $ ResponseGetAutocompletion []
            loop
          Right RequestShutdownSession ->
            putEnc $ ResponseShutdownSession
      where
        loop = go input spanInfo expTypes autoComplete

    ignoreProgress :: Progress -> IO ()
    ignoreProgress _ = return ()

-- | We sort the spans from thinnest to thickest. Currently
-- ide-backend sometimes returns results unsorted, therefore for now
-- we do the sort here, and in future ide-backend can be changed to do
-- this.
sortSpans :: [(SourceSpan,a)] -> [(SourceSpan,a)]
sortSpans = sortBy (on thinner fst)
  where thinner x y =
          comparing (if on (==) spanFromLine x y &&
                        on (==) spanToLine x y
                        then \(SourceSpan _ _ s _ e) -> e - s
                        else \(SourceSpan _ s _ e _) -> e - s)
                    x
                    y

-- | Construct autocomplete information
idInfoToAutocompletion :: IdInfo -> AutocompletionInfo
idInfoToAutocompletion IdInfo{idProp = IdProp{idName, idDefinedIn, idType}, idScope} =
  AutocompletionInfo definedIn idName qualifier idType
  where definedIn = moduleName idDefinedIn
        qualifier = case idScope of
                     Binder                 -> Nothing
                     Local{}                -> Nothing
                     Imported{idImportQual} -> mfilter (not . Text.null) (Just idImportQual)
                     WiredIn                -> Nothing

makeSessionUpdate :: RequestSessionUpdate -> IdeSessionUpdate
makeSessionUpdate (RequestUpdateSourceFile filePath contents) =
  updateSourceFile filePath contents
makeSessionUpdate (RequestUpdateSourceFileFromFile filePath) =
  updateSourceFileFromFile filePath
makeSessionUpdate (RequestUpdateGhcOpts options) =
  updateGhcOpts options

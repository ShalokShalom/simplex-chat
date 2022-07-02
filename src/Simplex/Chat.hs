{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Chat where

import Control.Applicative (optional, (<|>))
import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random (drgNew)
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64 as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isSpace)
import Data.Fixed (div')
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find, isSuffixOf)
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Data.Time.Clock.System (SystemTime, systemToUTCTime)
import Data.Time.LocalTime (getCurrentTimeZone, getZonedTime)
import Data.Word (Word32)
import qualified Database.SQLite.Simple as DB
import Simplex.Chat.Archive
import Simplex.Chat.Call
import Simplex.Chat.Controller
import Simplex.Chat.Markdown
import Simplex.Chat.Messages
import Simplex.Chat.Options (ChatOpts (..), smpServersP)
import Simplex.Chat.Protocol
import Simplex.Chat.Store
import Simplex.Chat.Types
import Simplex.Chat.Util (safeDecodeUtf8, uncurry3)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), InitialAgentServers (..), defaultAgentConfig)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Types (NtfServer)
import Simplex.Messaging.Parsers (base64P, parseAll)
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody, MsgFlags (..))
import qualified Simplex.Messaging.Protocol as SMP
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, liftEitherError, tryError, unlessM, whenM, (<$?>))
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (combine, splitExtensions, takeFileName)
import System.IO (Handle, IOMode (..), SeekMode (..), hFlush, openFile, stdout)
import Text.Read (readMaybe)
import UnliftIO.Async
import UnliftIO.Concurrent (forkIO, threadDelay)
import UnliftIO.Directory
import qualified UnliftIO.Exception as E
import UnliftIO.IO (hClose, hSeek, hTell)
import UnliftIO.STM

defaultChatConfig :: ChatConfig
defaultChatConfig =
  ChatConfig
    { agentConfig =
        defaultAgentConfig
          { tcpPort = undefined, -- agent does not listen to TCP
            dbFile = "simplex_v1",
            yesToMigrations = False
          },
      yesToMigrations = False,
      defaultServers = InitialAgentServers {smp = _defaultSMPServers, ntf = _defaultNtfServers},
      tbqSize = 64,
      fileChunkSize = 15780,
      subscriptionConcurrency = 16,
      subscriptionEvents = False,
      testView = False
    }

_defaultSMPServers :: NonEmpty SMPServer
_defaultSMPServers =
  L.fromList
    [ "smp://0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU=@smp8.simplex.im",
      "smp://SkIkI6EPd2D63F4xFKfHk7I1UGZVNn6k1QWZ5rcyr6w=@smp9.simplex.im",
      "smp://6iIcWT_dF2zN_w5xzZEY7HI2Prbh3ldP07YTyDexPjE=@smp10.simplex.im"
    ]

_defaultNtfServers :: [NtfServer]
_defaultNtfServers = ["smp://FB-Uop7RTaZZEG0ZLD2CIaTjsPh-Fw0zFAnb7QyA8Ks=@ntf2.simplex.im"]

maxImageSize :: Integer
maxImageSize = 236700

fixedImagePreview :: ImageData
fixedImagePreview = ImageData "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAAXNSR0IArs4c6QAAAKVJREFUeF7t1kENACEUQ0FQhnVQ9lfGO+xggITQdvbMzArPey+8fa3tAfwAEdABZQspQStgBssEcgAIkSAJkiAJljtEgiRIgmUCSZAESZAESZAEyx0iQRIkwTKBJEiCv5fgvTd1wDmn7QAP4AeIgA4oW0gJWgEzWCZwbQ7gAA7ggLKFOIADOKBMIAeAEAmSIAmSYLlDJEiCJFgmkARJkARJ8N8S/ADTZUewBvnTOQAAAABJRU5ErkJggg=="

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

newChatController :: SQLiteStore -> Maybe User -> ChatConfig -> ChatOpts -> Maybe (Notification -> IO ()) -> IO ChatController
newChatController chatStore user cfg@ChatConfig {agentConfig = aCfg, tbqSize, defaultServers} ChatOpts {dbFilePrefix, smpServers, logConnections} sendToast = do
  let f = chatStoreFile dbFilePrefix
      config = cfg {subscriptionEvents = logConnections}
      sendNotification = fromMaybe (const $ pure ()) sendToast
  activeTo <- newTVarIO ActiveNone
  firstTime <- not <$> doesFileExist f
  currentUser <- newTVarIO user
  servers <- resolveServers defaultServers
  smpAgent <- getSMPAgentClient aCfg {dbFile = dbFilePrefix <> "_agent.db"} servers
  agentAsync <- newTVarIO Nothing
  idsDrg <- newTVarIO =<< drgNew
  inputQ <- newTBQueueIO tbqSize
  outputQ <- newTBQueueIO tbqSize
  notifyQ <- newTBQueueIO tbqSize
  chatLock <- newTMVarIO ()
  sndFiles <- newTVarIO M.empty
  rcvFiles <- newTVarIO M.empty
  currentCalls <- atomically TM.empty
  filesFolder <- newTVarIO Nothing
  chatStoreChanged <- newTVarIO False
  pure ChatController {activeTo, firstTime, currentUser, smpAgent, agentAsync, chatStore, chatStoreChanged, idsDrg, inputQ, outputQ, notifyQ, chatLock, sndFiles, rcvFiles, currentCalls, config, sendNotification, filesFolder}
  where
    resolveServers :: InitialAgentServers -> IO InitialAgentServers
    resolveServers ss@InitialAgentServers {smp = defaultSMPServers} = case nonEmpty smpServers of
      Just smpServers' -> pure ss {smp = smpServers'}
      _ -> case user of
        Just usr -> do
          userSmpServers <- withTransaction chatStore (`getSMPServers` usr)
          pure ss {smp = fromMaybe defaultSMPServers $ nonEmpty userSmpServers}
        _ -> pure ss

runChatController :: (MonadUnliftIO m, MonadReader ChatController m) => User -> Bool -> m ()
runChatController user subConns = race_ notificationSubscriber $ agentSubscriber user subConns

startChatController :: (MonadUnliftIO m, MonadReader ChatController m) => User -> Bool -> m (Async ())
startChatController user subConns = do
  asks smpAgent >>= resumeAgentClient
  s <- asks agentAsync
  readTVarIO s >>= maybe (start s) pure
  where
    start s = do
      a <- async $ runChatController user subConns
      atomically . writeTVar s $ Just a
      pure a

stopChatController :: MonadUnliftIO m => ChatController -> m ()
stopChatController ChatController {smpAgent, agentAsync = s} = do
  disconnectAgentClient smpAgent
  readTVarIO s >>= mapM_ uninterruptibleCancel >> atomically (writeTVar s Nothing)

withLock :: MonadUnliftIO m => TMVar () -> m a -> m a
withLock lock =
  E.bracket_
    (void . atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())

execChatCommand :: (MonadUnliftIO m, MonadReader ChatController m) => ByteString -> m ChatResponse
execChatCommand s = case parseChatCommand s of
  Left e -> pure $ chatCmdError e
  Right cmd -> either CRChatCmdError id <$> runExceptT (processChatCommand cmd)

parseChatCommand :: ByteString -> Either String ChatCommand
parseChatCommand = parseAll chatCommandP . B.dropWhileEnd isSpace

toView :: ChatMonad m => ChatResponse -> m ()
toView event = do
  q <- asks outputQ
  atomically $ writeTBQueue q (Nothing, event)

processChatCommand :: forall m. ChatMonad m => ChatCommand -> m ChatResponse
processChatCommand = \case
  ShowActiveUser -> withUser' $ pure . CRActiveUser
  CreateActiveUser p -> do
    u <- asks currentUser
    whenM (isJust <$> readTVarIO u) $ throwChatError CEActiveUserExists
    user <- withStore $ \db -> createUser db p True
    atomically . writeTVar u $ Just user
    pure $ CRActiveUser user
  StartChat subConns -> withUser' $ \user ->
    asks agentAsync >>= readTVarIO >>= \case
      Just _ -> pure CRChatRunning
      _ ->
        ifM
          (asks chatStoreChanged >>= readTVarIO)
          (throwChatError CEChatStoreChanged)
          (startChatController user subConns $> CRChatStarted)
  APIStopChat -> do
    ask >>= stopChatController
    pure CRChatStopped
  APIActivateChat -> withAgent activateAgent $> CRCmdOk
  APISuspendChat t -> withAgent (`suspendAgent` t) $> CRCmdOk
  ResubscribeAllConnections -> withUser (subscribeUserConnections resubscribeConnection) $> CRCmdOk
  SetFilesFolder filesFolder' -> do
    createDirectoryIfMissing True filesFolder'
    ff <- asks filesFolder
    atomically . writeTVar ff $ Just filesFolder'
    pure CRCmdOk
  APIExportArchive cfg -> checkChatStopped $ exportArchive cfg $> CRCmdOk
  APIImportArchive cfg -> checkChatStopped $ importArchive cfg >> setStoreChanged $> CRCmdOk
  APIDeleteStorage -> checkChatStopped $ deleteStorage >> setStoreChanged $> CRCmdOk
  APIGetChats withPCC -> CRApiChats <$> withUser (\user -> withStore' $ \db -> getChatPreviews db user withPCC)
  APIGetChat (ChatRef cType cId) pagination -> withUser $ \user -> case cType of
    CTDirect -> CRApiChat . AChat SCTDirect <$> withStore (\db -> getDirectChat db user cId pagination)
    CTGroup -> CRApiChat . AChat SCTGroup <$> withStore (\db -> getGroupChat db user cId pagination)
    CTContactRequest -> pure $ chatCmdError "not implemented"
    CTContactConnection -> pure $ chatCmdError "not supported"
  APIGetChatItems _pagination -> pure $ chatCmdError "not implemented"
  APISendMessage (ChatRef cType chatId) (ComposedMessage file_ quotedItemId_ mc) -> withUser $ \user@User {userId} -> withChatLock $ case cType of
    CTDirect -> do
      ct@Contact {localDisplayName = c} <- withStore $ \db -> getContact db userId chatId
      (fileInvitation_, ciFile_) <- unzipMaybe <$> setupSndFileTransfer ct
      (msgContainer, quotedItem_) <- prepareMsg fileInvitation_
      msg <- sendDirectContactMessage ct (XMsgNew msgContainer)
      ci <- saveSndChatItem user (CDDirectSnd ct) msg (CISndMsgContent mc) ciFile_ quotedItem_
      setActive $ ActiveC c
      pure . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat ct) ci
      where
        setupSndFileTransfer :: Contact -> m (Maybe (FileInvitation, CIFile 'MDSnd))
        setupSndFileTransfer ct = case file_ of
          Nothing -> pure Nothing
          Just file -> do
            (fileSize, chSize) <- checkSndFile file
            (agentConnId, fileConnReq) <- withAgent (`createConnection` SCMInvitation)
            let fileName = takeFileName file
                fileInvitation = FileInvitation {fileName, fileSize, fileConnReq = Just fileConnReq}
            fileId <- withStore' $ \db -> createSndFileTransfer db userId ct file fileInvitation agentConnId chSize
            let ciFile = CIFile {fileId, fileName, fileSize, filePath = Just file, fileStatus = CIFSSndStored}
            pure $ Just (fileInvitation, ciFile)
        prepareMsg :: Maybe FileInvitation -> m (MsgContainer, Maybe (CIQuote 'CTDirect))
        prepareMsg fileInvitation_ = case quotedItemId_ of
          Nothing -> pure (MCSimple (ExtMsgContent mc fileInvitation_), Nothing)
          Just quotedItemId -> do
            CChatItem _ ChatItem {meta = CIMeta {itemTs, itemSharedMsgId}, content = ciContent, formattedText, file} <-
              withStore $ \db -> getDirectChatItem db userId chatId quotedItemId
            (origQmc, qd, sent) <- quoteData ciContent
            let msgRef = MsgRef {msgId = itemSharedMsgId, sentAt = itemTs, sent, memberId = Nothing}
                qmc = quoteContent origQmc file
                quotedItem = CIQuote {chatDir = qd, itemId = Just quotedItemId, sharedMsgId = itemSharedMsgId, sentAt = itemTs, content = qmc, formattedText}
            pure (MCQuote QuotedMsg {msgRef, content = qmc} (ExtMsgContent mc fileInvitation_), Just quotedItem)
          where
            quoteData :: CIContent d -> m (MsgContent, CIQDirection 'CTDirect, Bool)
            quoteData (CISndMsgContent qmc) = pure (qmc, CIQDirectSnd, True)
            quoteData (CIRcvMsgContent qmc) = pure (qmc, CIQDirectRcv, False)
            quoteData _ = throwChatError CEInvalidQuote
    CTGroup -> do
      Group gInfo@GroupInfo {membership, localDisplayName = gName} ms <- withStore $ \db -> getGroup db user chatId
      unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
      (fileInvitation_, ciFile_) <- unzipMaybe <$> setupSndFileTransfer gInfo
      (msgContainer, quotedItem_) <- prepareMsg fileInvitation_ membership
      msg <- sendGroupMessage gInfo ms (XMsgNew msgContainer)
      ci <- saveSndChatItem user (CDGroupSnd gInfo) msg (CISndMsgContent mc) ciFile_ quotedItem_
      setActive $ ActiveG gName
      pure . CRNewChatItem $ AChatItem SCTGroup SMDSnd (GroupChat gInfo) ci
      where
        setupSndFileTransfer :: GroupInfo -> m (Maybe (FileInvitation, CIFile 'MDSnd))
        setupSndFileTransfer gInfo = case file_ of
          Nothing -> pure Nothing
          Just file -> do
            (fileSize, chSize) <- checkSndFile file
            let fileName = takeFileName file
                fileInvitation = FileInvitation {fileName, fileSize, fileConnReq = Nothing}
            fileId <- withStore' $ \db -> createSndGroupFileTransfer db userId gInfo file fileInvitation chSize
            let ciFile = CIFile {fileId, fileName, fileSize, filePath = Just file, fileStatus = CIFSSndStored}
            pure $ Just (fileInvitation, ciFile)
        prepareMsg :: Maybe FileInvitation -> GroupMember -> m (MsgContainer, Maybe (CIQuote 'CTGroup))
        prepareMsg fileInvitation_ membership = case quotedItemId_ of
          Nothing -> pure (MCSimple (ExtMsgContent mc fileInvitation_), Nothing)
          Just quotedItemId -> do
            CChatItem _ ChatItem {chatDir, meta = CIMeta {itemTs, itemSharedMsgId}, content = ciContent, formattedText, file} <-
              withStore $ \db -> getGroupChatItem db user chatId quotedItemId
            (origQmc, qd, sent, GroupMember {memberId}) <- quoteData ciContent chatDir membership
            let msgRef = MsgRef {msgId = itemSharedMsgId, sentAt = itemTs, sent, memberId = Just memberId}
                qmc = quoteContent origQmc file
                quotedItem = CIQuote {chatDir = qd, itemId = Just quotedItemId, sharedMsgId = itemSharedMsgId, sentAt = itemTs, content = qmc, formattedText}
            pure (MCQuote QuotedMsg {msgRef, content = qmc} (ExtMsgContent mc fileInvitation_), Just quotedItem)
          where
            quoteData :: CIContent d -> CIDirection 'CTGroup d -> GroupMember -> m (MsgContent, CIQDirection 'CTGroup, Bool, GroupMember)
            quoteData (CISndMsgContent qmc) CIGroupSnd membership' = pure (qmc, CIQGroupSnd, True, membership')
            quoteData (CIRcvMsgContent qmc) (CIGroupRcv m) _ = pure (qmc, CIQGroupRcv $ Just m, False, m)
            quoteData _ _ _ = throwChatError CEInvalidQuote
    CTContactRequest -> pure $ chatCmdError "not supported"
    CTContactConnection -> pure $ chatCmdError "not supported"
    where
      quoteContent :: forall d. MsgContent -> Maybe (CIFile d) -> MsgContent
      quoteContent qmc ciFile_
        | replaceContent = MCText qTextOrFile
        | otherwise = case qmc of
          MCImage _ image -> MCImage qTextOrFile image
          MCFile _ -> MCFile qTextOrFile
          _ -> qmc
        where
          -- if the message we're quoting with is one of the "large" MsgContents
          -- we replace the quote's content with MCText
          replaceContent = case mc of
            MCText _ -> False
            MCFile _ -> False
            MCLink {} -> True
            MCImage {} -> True
            MCUnknown {} -> True
          qText = msgContentText qmc
          qFileName = maybe qText (T.pack . (fileName :: CIFile d -> String)) ciFile_
          qTextOrFile = if T.null qText then qFileName else qText
      unzipMaybe :: Maybe (a, b) -> (Maybe a, Maybe b)
      unzipMaybe t = (fst <$> t, snd <$> t)
  APIUpdateChatItem (ChatRef cType chatId) itemId mc -> withUser $ \user@User {userId} -> withChatLock $ case cType of
    CTDirect -> do
      (ct@Contact {contactId, localDisplayName = c}, ci) <- withStore $ \db -> (,) <$> getContact db userId chatId <*> getDirectChatItem db userId chatId itemId
      case ci of
        CChatItem SMDSnd ChatItem {meta = CIMeta {itemSharedMsgId}, content = ciContent} -> do
          case (ciContent, itemSharedMsgId) of
            (CISndMsgContent _, Just itemSharedMId) -> do
              SndMessage {msgId} <- sendDirectContactMessage ct (XMsgUpdate itemSharedMId mc)
              updCi <- withStore $ \db -> updateDirectChatItem db userId contactId itemId (CISndMsgContent mc) $ Just msgId
              setActive $ ActiveC c
              pure . CRChatItemUpdated $ AChatItem SCTDirect SMDSnd (DirectChat ct) updCi
            _ -> throwChatError CEInvalidChatItemUpdate
        CChatItem SMDRcv _ -> throwChatError CEInvalidChatItemUpdate
    CTGroup -> do
      Group gInfo@GroupInfo {groupId, localDisplayName = gName, membership} ms <- withStore $ \db -> getGroup db user chatId
      unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
      ci <- withStore $ \db -> getGroupChatItem db user chatId itemId
      case ci of
        CChatItem SMDSnd ChatItem {meta = CIMeta {itemSharedMsgId}, content = ciContent} -> do
          case (ciContent, itemSharedMsgId) of
            (CISndMsgContent _, Just itemSharedMId) -> do
              SndMessage {msgId} <- sendGroupMessage gInfo ms (XMsgUpdate itemSharedMId mc)
              updCi <- withStore $ \db -> updateGroupChatItem db user groupId itemId (CISndMsgContent mc) msgId
              setActive $ ActiveG gName
              pure . CRChatItemUpdated $ AChatItem SCTGroup SMDSnd (GroupChat gInfo) updCi
            _ -> throwChatError CEInvalidChatItemUpdate
        CChatItem SMDRcv _ -> throwChatError CEInvalidChatItemUpdate
    CTContactRequest -> pure $ chatCmdError "not supported"
    CTContactConnection -> pure $ chatCmdError "not supported"
  APIDeleteChatItem (ChatRef cType chatId) itemId mode -> withUser $ \user@User {userId} -> withChatLock $ case cType of
    CTDirect -> do
      (ct@Contact {localDisplayName = c}, CChatItem msgDir deletedItem@ChatItem {meta = CIMeta {itemSharedMsgId}, file}) <- withStore $ \db -> (,) <$> getContact db userId chatId <*> getDirectChatItem db userId chatId itemId
      case (mode, msgDir, itemSharedMsgId) of
        (CIDMInternal, _, _) -> do
          deleteCIFile user file
          toCi <- withStore $ \db -> deleteDirectChatItemLocal db userId ct itemId CIDMInternal
          pure $ CRChatItemDeleted (AChatItem SCTDirect msgDir (DirectChat ct) deletedItem) toCi
        (CIDMBroadcast, SMDSnd, Just itemSharedMId) -> do
          void $ sendDirectContactMessage ct (XMsgDel itemSharedMId)
          deleteCIFile user file
          toCi <- withStore $ \db -> deleteDirectChatItemLocal db userId ct itemId CIDMBroadcast
          setActive $ ActiveC c
          pure $ CRChatItemDeleted (AChatItem SCTDirect msgDir (DirectChat ct) deletedItem) toCi
        (CIDMBroadcast, _, _) -> throwChatError CEInvalidChatItemDelete
    -- TODO for group integrity and pending messages, group items and messages are set to "deleted"; maybe a different workaround is needed
    CTGroup -> do
      Group gInfo@GroupInfo {localDisplayName = gName, membership} ms <- withStore $ \db -> getGroup db user chatId
      unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
      CChatItem msgDir deletedItem@ChatItem {meta = CIMeta {itemSharedMsgId}, file} <- withStore $ \db -> getGroupChatItem db user chatId itemId
      case (mode, msgDir, itemSharedMsgId) of
        (CIDMInternal, _, _) -> do
          deleteCIFile user file
          toCi <- withStore $ \db -> deleteGroupChatItemInternal db user gInfo itemId
          pure $ CRChatItemDeleted (AChatItem SCTGroup msgDir (GroupChat gInfo) deletedItem) toCi
        (CIDMBroadcast, SMDSnd, Just itemSharedMId) -> do
          SndMessage {msgId} <- sendGroupMessage gInfo ms (XMsgDel itemSharedMId)
          deleteCIFile user file
          toCi <- withStore $ \db -> deleteGroupChatItemSndBroadcast db user gInfo itemId msgId
          setActive $ ActiveG gName
          pure $ CRChatItemDeleted (AChatItem SCTGroup msgDir (GroupChat gInfo) deletedItem) toCi
        (CIDMBroadcast, _, _) -> throwChatError CEInvalidChatItemDelete
    CTContactRequest -> pure $ chatCmdError "not supported"
    CTContactConnection -> pure $ chatCmdError "not supported"
    where
      deleteCIFile :: MsgDirectionI d => User -> Maybe (CIFile d) -> m ()
      deleteCIFile user file =
        forM_ file $ \CIFile {fileId, filePath, fileStatus} -> do
          let fileInfo = CIFileInfo {fileId, fileStatus = AFS msgDirection fileStatus, filePath}
          cancelFile user fileInfo
          withFilesFolder $ \filesFolder -> deleteFile filesFolder fileInfo
  APIChatRead (ChatRef cType chatId) fromToIds -> withChatLock $ case cType of
    CTDirect -> withStore' (\db -> updateDirectChatItemsRead db chatId fromToIds) $> CRCmdOk
    CTGroup -> withStore' (\db -> updateGroupChatItemsRead db chatId fromToIds) $> CRCmdOk
    CTContactRequest -> pure $ chatCmdError "not supported"
    CTContactConnection -> pure $ chatCmdError "not supported"
  APIDeleteChat (ChatRef cType chatId) -> withUser $ \user@User {userId} -> case cType of
    CTDirect -> do
      ct@Contact {localDisplayName} <- withStore $ \db -> getContact db userId chatId
      withStore' (\db -> getContactGroupNames db userId ct) >>= \case
        [] -> do
          filesInfo <- withStore' $ \db -> getContactFileInfo db userId ct
          conns <- withStore $ \db -> getContactConnections db userId ct
          withChatLock . procCmd $ do
            forM_ filesInfo $ \fileInfo -> do
              cancelFile user fileInfo
              withFilesFolder $ \filesFolder -> deleteFile filesFolder fileInfo
            withAgent $ \a -> forM_ conns $ \conn ->
              deleteConnection a (aConnId conn) `catchError` \(_ :: AgentErrorType) -> pure ()
            -- two functions below are called in separate transactions to prevent crashes on android
            -- (possibly, race condition on integrity check?)
            withStore' $ \db -> deleteContactConnectionsAndFiles db userId ct
            withStore' $ \db -> deleteContact db userId ct
            unsetActive $ ActiveC localDisplayName
            pure $ CRContactDeleted ct
        gs -> throwChatError $ CEContactGroups ct gs
    CTContactConnection -> withChatLock . procCmd $ do
      conn <- withStore $ \db -> getPendingContactConnection db userId chatId
      withAgent $ \a -> deleteConnection a $ aConnId' conn
      withStore' $ \db -> deletePendingContactConnection db userId chatId
      pure $ CRContactConnectionDeleted conn
    CTGroup -> pure $ chatCmdError "not implemented"
    CTContactRequest -> pure $ chatCmdError "not supported"
  APIClearChat (ChatRef cType chatId) -> withUser $ \user@User {userId} -> case cType of
    CTDirect -> do
      ct <- withStore $ \db -> getContact db userId chatId
      ciIdsAndFileInfo <- withStore' $ \db -> getContactChatItemIdsAndFileInfo db user chatId
      forM_ ciIdsAndFileInfo $ \(itemId, _, fileInfo_) -> do
        forM_ fileInfo_ $ \fileInfo -> do
          cancelFile user fileInfo
          withFilesFolder $ \filesFolder -> deleteFile filesFolder fileInfo
        void $ withStore $ \db -> deleteDirectChatItemLocal db userId ct itemId CIDMInternal
      ct' <- case ciIdsAndFileInfo of
        [] -> pure ct
        _ -> do
          let (_, lastItemTs, _) = last ciIdsAndFileInfo
          withStore' $ \db -> updateContactTs db user ct lastItemTs
          pure (ct :: Contact) {updatedAt = lastItemTs}
      pure $ CRChatCleared (AChatInfo SCTDirect (DirectChat ct'))
    CTGroup -> do
      gInfo <- withStore $ \db -> getGroupInfo db user chatId
      ciIdsAndFileInfo <- withStore' $ \db -> getGroupChatItemIdsAndFileInfo db user chatId
      forM_ ciIdsAndFileInfo $ \(itemId, _, itemDeleted, fileInfo_) ->
        unless itemDeleted $ do
          forM_ fileInfo_ $ \fileInfo -> do
            cancelFile user fileInfo
            withFilesFolder $ \filesFolder -> deleteFile filesFolder fileInfo
          void $ withStore $ \db -> deleteGroupChatItemInternal db user gInfo itemId
      gInfo' <- case ciIdsAndFileInfo of
        [] -> pure gInfo
        _ -> do
          let (_, lastItemTs, _, _) = last ciIdsAndFileInfo
          withStore' $ \db -> updateGroupTs db user gInfo lastItemTs
          pure (gInfo :: GroupInfo) {updatedAt = lastItemTs}
      pure $ CRChatCleared (AChatInfo SCTGroup (GroupChat gInfo'))
    CTContactConnection -> pure $ chatCmdError "not supported"
    CTContactRequest -> pure $ chatCmdError "not supported"
  APIAcceptContact connReqId -> withUser $ \user@User {userId} -> withChatLock $ do
    cReq <- withStore $ \db -> getContactRequest db userId connReqId
    procCmd $ CRAcceptingContactRequest <$> acceptContactRequest user cReq
  APIRejectContact connReqId -> withUser $ \User {userId} -> withChatLock $ do
    cReq@UserContactRequest {agentContactConnId = AgentConnId connId, agentInvitationId = AgentInvId invId} <-
      withStore $ \db ->
        getContactRequest db userId connReqId
          `E.finally` liftIO (deleteContactRequest db userId connReqId)
    withAgent $ \a -> rejectContact a connId invId
    pure $ CRContactRequestRejected cReq
  APISendCallInvitation contactId callType -> withUser $ \user@User {userId} -> do
    -- party initiating call
    ct <- withStore $ \db -> getContact db userId contactId
    calls <- asks currentCalls
    withChatLock $ do
      callId <- CallId <$> (asks idsDrg >>= liftIO . (`randomBytes` 16))
      dhKeyPair <- if encryptedCall callType then Just <$> liftIO C.generateKeyPair' else pure Nothing
      let invitation = CallInvitation {callType, callDhPubKey = fst <$> dhKeyPair}
          callState = CallInvitationSent {localCallType = callType, localDhPrivKey = snd <$> dhKeyPair}
      msg <- sendDirectContactMessage ct (XCallInv callId invitation)
      ci <- saveSndChatItem user (CDDirectSnd ct) msg (CISndCall CISCallPending 0) Nothing Nothing
      let call' = Call {contactId, callId, chatItemId = chatItemId' ci, callState}
      call_ <- atomically $ TM.lookupInsert contactId call' calls
      forM_ call_ $ \call -> updateCallItemStatus userId ct call WCSDisconnected Nothing
      toView . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat ct) ci
      pure CRCmdOk
  SendCallInvitation cName callType -> withUser $ \User {userId} -> do
    contactId <- withStore $ \db -> getContactIdByName db userId cName
    processChatCommand $ APISendCallInvitation contactId callType
  APIRejectCall contactId ->
    -- party accepting call
    withCurrentCall contactId $ \userId ct Call {chatItemId, callState} -> case callState of
      CallInvitationReceived {} -> do
        let aciContent = ACIContent SMDRcv $ CIRcvCall CISCallRejected 0
        withStore' $ \db -> updateDirectChatItemsRead db contactId $ Just (chatItemId, chatItemId)
        updateDirectChatItemView userId ct chatItemId aciContent Nothing $> Nothing
      _ -> throwChatError . CECallState $ callStateTag callState
  APISendCallOffer contactId WebRTCCallOffer {callType, rtcSession} ->
    -- party accepting call
    withCurrentCall contactId $ \userId ct call@Call {callId, chatItemId, callState} -> case callState of
      CallInvitationReceived {peerCallType, localDhPubKey, sharedKey} -> do
        let callDhPubKey = if encryptedCall callType then localDhPubKey else Nothing
            offer = CallOffer {callType, rtcSession, callDhPubKey}
            callState' = CallOfferSent {localCallType = callType, peerCallType, localCallSession = rtcSession, sharedKey}
            aciContent = ACIContent SMDRcv $ CIRcvCall CISCallAccepted 0
        SndMessage {msgId} <- sendDirectContactMessage ct (XCallOffer callId offer)
        withStore' $ \db -> updateDirectChatItemsRead db contactId $ Just (chatItemId, chatItemId)
        updateDirectChatItemView userId ct chatItemId aciContent $ Just msgId
        pure $ Just call {callState = callState'}
      _ -> throwChatError . CECallState $ callStateTag callState
  APISendCallAnswer contactId rtcSession ->
    -- party initiating call
    withCurrentCall contactId $ \userId ct call@Call {callId, chatItemId, callState} -> case callState of
      CallOfferReceived {localCallType, peerCallType, peerCallSession, sharedKey} -> do
        let callState' = CallNegotiated {localCallType, peerCallType, localCallSession = rtcSession, peerCallSession, sharedKey}
            aciContent = ACIContent SMDSnd $ CISndCall CISCallNegotiated 0
        SndMessage {msgId} <- sendDirectContactMessage ct (XCallAnswer callId CallAnswer {rtcSession})
        updateDirectChatItemView userId ct chatItemId aciContent $ Just msgId
        pure $ Just call {callState = callState'}
      _ -> throwChatError . CECallState $ callStateTag callState
  APISendCallExtraInfo contactId rtcExtraInfo ->
    -- any call party
    withCurrentCall contactId $ \_ ct call@Call {callId, callState} -> case callState of
      CallOfferSent {localCallType, peerCallType, localCallSession, sharedKey} -> do
        -- TODO update the list of ice servers in localCallSession
        _ <- sendDirectContactMessage ct (XCallExtra callId CallExtraInfo {rtcExtraInfo})
        let callState' = CallOfferSent {localCallType, peerCallType, localCallSession, sharedKey}
        pure $ Just call {callState = callState'}
      CallNegotiated {localCallType, peerCallType, localCallSession, peerCallSession, sharedKey} -> do
        -- TODO update the list of ice servers in localCallSession
        _ <- sendDirectContactMessage ct (XCallExtra callId CallExtraInfo {rtcExtraInfo})
        let callState' = CallNegotiated {localCallType, peerCallType, localCallSession, peerCallSession, sharedKey}
        pure $ Just call {callState = callState'}
      _ -> throwChatError . CECallState $ callStateTag callState
  APIEndCall contactId ->
    -- any call party
    withCurrentCall contactId $ \userId ct call@Call {callId} -> do
      SndMessage {msgId} <- sendDirectContactMessage ct (XCallEnd callId)
      updateCallItemStatus userId ct call WCSDisconnected $ Just msgId
      pure Nothing
  APICallStatus contactId receivedStatus ->
    withCurrentCall contactId $ \userId ct call ->
      updateCallItemStatus userId ct call receivedStatus Nothing $> Just call
  APIUpdateProfile profile -> withUser (`updateProfile` profile)
  APIParseMarkdown text -> pure . CRApiParsedMarkdown $ parseMaybeMarkdownList text
  APIGetNtfToken -> withUser $ \_ -> crNtfToken <$> withAgent getNtfToken
  APIRegisterToken token mode -> CRNtfTokenStatus <$> withUser (\_ -> withAgent $ \a -> registerNtfToken a token mode)
  APIVerifyToken token nonce code -> withUser $ \_ -> withAgent (\a -> verifyNtfToken a token nonce code) $> CRCmdOk
  APIDeleteToken token -> withUser $ \_ -> withAgent (`deleteNtfToken` token) $> CRCmdOk
  APIGetNtfMessage nonce encNtfInfo -> withUser $ \user -> do
    (NotificationInfo {ntfConnId, ntfMsgMeta}, msgs) <- withAgent $ \a -> getNotificationMessage a nonce encNtfInfo
    let ntfMessages = map (\SMP.SMPMsgMeta {msgTs, msgFlags} -> NtfMsgInfo {msgTs = systemToUTCTime msgTs, msgFlags}) msgs
        msgTs' = systemToUTCTime . (SMP.msgTs :: SMP.NMsgMeta -> SystemTime) <$> ntfMsgMeta
    connEntity <- withStore (\db -> Just <$> getConnectionEntity db user ntfConnId) `catchError` \_ -> pure Nothing
    pure CRNtfMessages {connEntity, msgTs = msgTs', ntfMessages}
  GetUserSMPServers -> CRUserSMPServers <$> withUser (\user -> withStore' (`getSMPServers` user))
  SetUserSMPServers smpServers -> withUser $ \user -> withChatLock $ do
    withStore $ \db -> overwriteSMPServers db user smpServers
    ChatConfig {defaultServers = InitialAgentServers {smp = defaultSMPServers}} <- asks config
    withAgent $ \a -> setSMPServers a (fromMaybe defaultSMPServers (nonEmpty smpServers))
    pure CRCmdOk
  ChatHelp section -> pure $ CRChatHelp section
  Welcome -> withUser $ pure . CRWelcome
  AddContact -> withUser $ \User {userId} -> withChatLock . procCmd $ do
    (connId, cReq) <- withAgent (`createConnection` SCMInvitation)
    conn <- withStore' $ \db -> createDirectConnection db userId connId ConnNew
    toView $ CRNewContactConnection conn
    pure $ CRInvitation cReq
  Connect (Just (ACR SCMInvitation cReq)) -> withUser $ \User {userId, profile} -> withChatLock . procCmd $ do
    connId <- withAgent $ \a -> joinConnection a cReq . directMessage $ XInfo profile
    conn <- withStore' $ \db -> createDirectConnection db userId connId ConnJoined
    toView $ CRNewContactConnection conn
    pure CRSentConfirmation
  Connect (Just (ACR SCMContact cReq)) -> withUser $ \User {userId, profile} ->
    connectViaContact userId cReq profile
  Connect Nothing -> throwChatError CEInvalidConnReq
  ConnectSimplex -> withUser $ \User {userId, profile} ->
    connectViaContact userId adminContactReq profile
  DeleteContact cName -> withUser $ \User {userId} -> do
    contactId <- withStore $ \db -> getContactIdByName db userId cName
    processChatCommand $ APIDeleteChat (ChatRef CTDirect contactId)
  ClearContact cName -> withUser $ \User {userId} -> do
    contactId <- withStore $ \db -> getContactIdByName db userId cName
    processChatCommand $ APIClearChat (ChatRef CTDirect contactId)
  ListContacts -> withUser $ \user -> CRContactsList <$> withStore' (`getUserContacts` user)
  CreateMyAddress -> withUser $ \User {userId} -> withChatLock . procCmd $ do
    (connId, cReq) <- withAgent (`createConnection` SCMContact)
    withStore $ \db -> createUserContactLink db userId connId cReq
    pure $ CRUserContactLinkCreated cReq
  DeleteMyAddress -> withUser $ \User {userId} -> withChatLock $ do
    conns <- withStore (`getUserContactLinkConnections` userId)
    procCmd $ do
      withAgent $ \a -> forM_ conns $ \conn ->
        deleteConnection a (aConnId conn) `catchError` \(_ :: AgentErrorType) -> pure ()
      withStore' (`deleteUserContactLink` userId)
      pure CRUserContactLinkDeleted
  ShowMyAddress -> withUser $ \User {userId} ->
    uncurry3 CRUserContactLink <$> withStore (`getUserContactLink` userId)
  AddressAutoAccept onOff msgContent -> withUser $ \User {userId} -> do
    uncurry3 CRUserContactLinkUpdated <$> withStore (\db -> updateUserContactLinkAutoAccept db userId onOff msgContent)
  AcceptContact cName -> withUser $ \User {userId} -> do
    connReqId <- withStore $ \db -> getContactRequestIdByName db userId cName
    processChatCommand $ APIAcceptContact connReqId
  RejectContact cName -> withUser $ \User {userId} -> do
    connReqId <- withStore $ \db -> getContactRequestIdByName db userId cName
    processChatCommand $ APIRejectContact connReqId
  SendMessage chatName msg -> withUser $ \user -> do
    chatRef <- getChatRef user chatName
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand . APISendMessage chatRef $ ComposedMessage Nothing Nothing mc
  SendMessageBroadcast msg -> withUser $ \user -> do
    contacts <- withStore' (`getUserContacts` user)
    withChatLock . procCmd $ do
      let mc = MCText $ safeDecodeUtf8 msg
          cts = filter isReady contacts
      forM_ cts $ \ct ->
        void
          ( do
              sndMsg <- sendDirectContactMessage ct (XMsgNew $ MCSimple (ExtMsgContent mc Nothing))
              saveSndChatItem user (CDDirectSnd ct) sndMsg (CISndMsgContent mc) Nothing Nothing
          )
          `catchError` (toView . CRChatError)
      CRBroadcastSent mc (length cts) <$> liftIO getZonedTime
  SendMessageQuote cName (AMsgDirection msgDir) quotedMsg msg -> withUser $ \User {userId} -> do
    contactId <- withStore $ \db -> getContactIdByName db userId cName
    quotedItemId <- withStore $ \db -> getDirectChatItemIdByText db userId contactId msgDir (safeDecodeUtf8 quotedMsg)
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand . APISendMessage (ChatRef CTDirect contactId) $ ComposedMessage Nothing (Just quotedItemId) mc
  DeleteMessage chatName deletedMsg -> withUser $ \user -> do
    chatRef <- getChatRef user chatName
    deletedItemId <- getSentChatItemIdByText user chatRef deletedMsg
    processChatCommand $ APIDeleteChatItem chatRef deletedItemId CIDMBroadcast
  EditMessage chatName editedMsg msg -> withUser $ \user -> do
    chatRef <- getChatRef user chatName
    editedItemId <- getSentChatItemIdByText user chatRef editedMsg
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand $ APIUpdateChatItem chatRef editedItemId mc
  NewGroup gProfile -> withUser $ \user -> do
    gVar <- asks idsDrg
    CRGroupCreated <$> withStore (\db -> createNewGroup db gVar user gProfile)
  AddMember gName cName memRole -> withUser $ \user@User {userId} -> withChatLock $ do
    -- TODO for large groups: no need to load all members to determine if contact is a member
    (group, contact) <- withStore $ \db -> (,) <$> getGroupByName db user gName <*> getContactByName db userId cName
    let Group gInfo@GroupInfo {groupId, groupProfile, membership} members = group
        GroupMember {memberRole = userRole, memberId = userMemberId} = membership
    when (userRole < GRAdmin || userRole < memRole) $ throwChatError CEGroupUserRole
    when (memberStatus membership == GSMemInvited) $ throwChatError (CEGroupNotJoined gInfo)
    unless (memberActive membership) $ throwChatError CEGroupMemberNotActive
    let sendInvitation memberId cReq = do
          void . sendDirectContactMessage contact $
            XGrpInv $ GroupInvitation (MemberIdRole userMemberId userRole) (MemberIdRole memberId memRole) cReq groupProfile
          setActive $ ActiveG gName
          pure $ CRSentGroupInvitation gInfo contact
    case contactMember contact members of
      Nothing -> do
        gVar <- asks idsDrg
        (agentConnId, cReq) <- withAgent (`createConnection` SCMInvitation)
        GroupMember {memberId} <- withStore $ \db -> createContactMember db gVar user groupId contact memRole agentConnId cReq
        sendInvitation memberId cReq
      Just GroupMember {groupMemberId, memberId, memberStatus}
        | memberStatus == GSMemInvited ->
          withStore' (\db -> getMemberInvitation db user groupMemberId) >>= \case
            Just cReq -> sendInvitation memberId cReq
            Nothing -> throwChatError $ CEGroupCantResendInvitation gInfo cName
        | otherwise -> throwChatError $ CEGroupDuplicateMember cName
  JoinGroup gName -> withUser $ \user@User {userId} -> do
    ReceivedGroupInvitation {fromMember, connRequest, groupInfo = g} <- withStore $ \db -> getGroupInvitation db user gName
    withChatLock . procCmd $ do
      agentConnId <- withAgent $ \a -> joinConnection a connRequest . directMessage . XGrpAcpt $ memberId (membership g :: GroupMember)
      withStore' $ \db -> do
        createMemberConnection db userId fromMember agentConnId
        updateGroupMemberStatus db userId fromMember GSMemAccepted
        updateGroupMemberStatus db userId (membership g) GSMemAccepted
      pure $ CRUserAcceptedGroupSent g
  MemberRole _gName _cName _mRole -> throwChatError $ CECommandError "unsupported"
  RemoveMember gName cName -> withUser $ \user@User {userId} -> do
    Group gInfo@GroupInfo {membership} members <- withStore $ \db -> getGroupByName db user gName
    case find ((== cName) . (localDisplayName :: GroupMember -> ContactName)) members of
      Nothing -> throwChatError $ CEGroupMemberNotFound cName
      Just m@GroupMember {memberId = mId, memberRole = mRole, memberStatus = mStatus} -> do
        let userRole = memberRole (membership :: GroupMember)
        when (userRole < GRAdmin || userRole < mRole) $ throwChatError CEGroupUserRole
        withChatLock . procCmd $ do
          when (mStatus /= GSMemInvited) . void . sendGroupMessage gInfo members $ XGrpMemDel mId
          deleteMemberConnection m
          withStore' $ \db -> updateGroupMemberStatus db userId m GSMemRemoved
          pure $ CRUserDeletedMember gInfo m
  LeaveGroup gName -> withUser $ \user@User {userId} -> do
    Group gInfo@GroupInfo {membership} members <- withStore $ \db -> getGroupByName db user gName
    withChatLock . procCmd $ do
      void $ sendGroupMessage gInfo members XGrpLeave
      mapM_ deleteMemberConnection members
      withStore' $ \db -> updateGroupMemberStatus db userId membership GSMemLeft
      pure $ CRLeftMemberUser gInfo
  DeleteGroup gName -> withUser $ \user -> do
    g@(Group gInfo@GroupInfo {membership} members) <- withStore $ \db -> getGroupByName db user gName
    let s = memberStatus membership
        canDelete =
          memberRole (membership :: GroupMember) == GROwner
            || (s == GSMemRemoved || s == GSMemLeft || s == GSMemGroupDeleted || s == GSMemInvited)
    unless canDelete $ throwChatError CEGroupUserRole
    withChatLock . procCmd $ do
      when (memberActive membership) . void $ sendGroupMessage gInfo members XGrpDel
      mapM_ deleteMemberConnection members
      withStore' $ \db -> deleteGroup db user g
      pure $ CRGroupDeletedUser gInfo
  ClearGroup gName -> withUser $ \user -> do
    groupId <- withStore $ \db -> getGroupIdByName db user gName
    processChatCommand $ APIClearChat (ChatRef CTGroup groupId)
  ListMembers gName -> CRGroupMembers <$> withUser (\user -> withStore (\db -> getGroupByName db user gName))
  ListGroups -> CRGroupsList <$> withUser (\user -> withStore' (`getUserGroupDetails` user))
  SendGroupMessageQuote gName cName quotedMsg msg -> withUser $ \user -> do
    groupId <- withStore $ \db -> getGroupIdByName db user gName
    quotedItemId <- withStore $ \db -> getGroupChatItemIdByText db user groupId cName (safeDecodeUtf8 quotedMsg)
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand . APISendMessage (ChatRef CTGroup groupId) $ ComposedMessage Nothing (Just quotedItemId) mc
  LastMessages (Just chatName) count -> withUser $ \user -> do
    chatRef <- getChatRef user chatName
    CRLastMessages . aChatItems . chat <$> (processChatCommand . APIGetChat chatRef $ CPLast count)
  LastMessages Nothing count -> withUser $ \user -> withStore $ \db ->
    CRLastMessages <$> getAllChatItems db user (CPLast count)
  SendFile chatName f -> withUser $ \user -> do
    chatRef <- getChatRef user chatName
    processChatCommand . APISendMessage chatRef $ ComposedMessage (Just f) Nothing (MCFile "")
  SendImage chatName f -> withUser $ \user -> do
    chatRef <- getChatRef user chatName
    filePath <- toFSFilePath f
    unless (".jpg" `isSuffixOf` f || ".jpeg" `isSuffixOf` f) $ throwChatError CEFileImageType {filePath}
    fileSize <- getFileSize filePath
    unless (fileSize <= maxImageSize) $ throwChatError CEFileImageSize {filePath}
    processChatCommand . APISendMessage chatRef $ ComposedMessage (Just f) Nothing (MCImage "" fixedImagePreview)
  ForwardFile chatName fileId -> forwardFile chatName fileId SendFile
  ForwardImage chatName fileId -> forwardFile chatName fileId SendImage
  ReceiveFile fileId filePath_ -> withUser $ \user ->
    withChatLock . procCmd $ do
      ft <- withStore $ \db -> getRcvFileTransfer db user fileId
      (CRRcvFileAccepted <$> acceptFileReceive user ft filePath_) `catchError` processError ft
    where
      processError ft = \case
        -- TODO AChatItem in Cancelled events
        ChatErrorAgent (SMP SMP.AUTH) -> pure $ CRRcvFileAcceptedSndCancelled ft
        ChatErrorAgent (CONN DUPLICATE) -> pure $ CRRcvFileAcceptedSndCancelled ft
        e -> throwError e
  CancelFile fileId -> withUser $ \user@User {userId} ->
    withChatLock . procCmd $
      withStore (\db -> getFileTransfer db user fileId) >>= \case
        FTSnd ftm@FileTransferMeta {cancelled} fts -> do
          unless cancelled $ do
            cancelSndFile user ftm fts
            sharedMsgId <- withStore $ \db -> getSharedMsgIdByFileId db userId fileId
            void $
              withStore (\db -> getChatRefByFileId db user fileId) >>= \case
                ChatRef CTDirect contactId -> do
                  contact <- withStore $ \db -> getContact db userId contactId
                  sendDirectContactMessage contact $ XFileCancel sharedMsgId
                ChatRef CTGroup groupId -> do
                  Group gInfo ms <- withStore $ \db -> getGroup db user groupId
                  sendGroupMessage gInfo ms $ XFileCancel sharedMsgId
                _ -> throwChatError $ CEFileInternal "invalid chat ref for file transfer"
          ci <- withStore $ \db -> getChatItemByFileId db user fileId
          pure $ CRSndGroupFileCancelled ci ftm fts
        FTRcv ftr@RcvFileTransfer {cancelled} -> do
          unless cancelled $ cancelRcvFileTransfer user ftr
          pure $ CRRcvFileCancelled ftr
  FileStatus fileId ->
    CRFileTransferStatus <$> withUser (\user -> withStore $ \db -> getFileTransferProgress db user fileId)
  ShowProfile -> withUser $ \User {profile} -> pure $ CRUserProfile profile
  UpdateProfile displayName fullName -> withUser $ \user@User {profile} -> do
    let p = (profile :: Profile) {displayName = displayName, fullName = fullName}
    updateProfile user p
  UpdateProfileImage image -> withUser $ \user@User {profile} -> do
    let p = (profile :: Profile) {image}
    updateProfile user p
  QuitChat -> liftIO exitSuccess
  ShowVersion -> pure $ CRVersionInfo versionNumber
  where
    withChatLock action = do
      ChatController {chatLock = l, smpAgent = a} <- ask
      withAgentLock a . withLock l $ action
    -- below code would make command responses asynchronous where they can be slow
    -- in View.hs `r'` should be defined as `id` in this case
    -- procCmd :: m ChatResponse -> m ChatResponse
    -- procCmd action = do
    --   ChatController {chatLock = l, smpAgent = a, outputQ = q, idsDrg = gVar} <- ask
    --   corrId <- liftIO $ SMP.CorrId <$> randomBytes gVar 8
    --   void . forkIO $
    --     withAgentLock a . withLock l $
    --       (atomically . writeTBQueue q) . (Just corrId,) =<< (action `catchError` (pure . CRChatError))
    --   pure $ CRCmdAccepted corrId
    -- use function below to make commands "synchronous"
    procCmd :: m ChatResponse -> m ChatResponse
    procCmd = id
    getChatRef :: User -> ChatName -> m ChatRef
    getChatRef user@User {userId} (ChatName cType name) =
      ChatRef cType <$> case cType of
        CTDirect -> withStore $ \db -> getContactIdByName db userId name
        CTGroup -> withStore $ \db -> getGroupIdByName db user name
        _ -> throwChatError $ CECommandError "not supported"
    checkChatStopped :: m ChatResponse -> m ChatResponse
    checkChatStopped a = asks agentAsync >>= readTVarIO >>= maybe a (const $ throwChatError CEChatNotStopped)
    setStoreChanged :: m ()
    setStoreChanged = asks chatStoreChanged >>= atomically . (`writeTVar` True)
    getSentChatItemIdByText :: User -> ChatRef -> ByteString -> m Int64
    getSentChatItemIdByText user@User {userId, localDisplayName} (ChatRef cType cId) msg = case cType of
      CTDirect -> withStore $ \db -> getDirectChatItemIdByText db userId cId SMDSnd (safeDecodeUtf8 msg)
      CTGroup -> withStore $ \db -> getGroupChatItemIdByText db user cId (Just localDisplayName) (safeDecodeUtf8 msg)
      _ -> throwChatError $ CECommandError "not supported"
    connectViaContact :: UserId -> ConnectionRequestUri 'CMContact -> Profile -> m ChatResponse
    connectViaContact userId cReq profile = withChatLock $ do
      let cReqHash = ConnReqUriHash . C.sha256Hash $ strEncode cReq
      withStore' (\db -> getConnReqContactXContactId db userId cReqHash) >>= \case
        (Just contact, _) -> pure $ CRContactAlreadyExists contact
        (_, xContactId_) -> procCmd $ do
          let randomXContactId = XContactId <$> (asks idsDrg >>= liftIO . (`randomBytes` 16))
          xContactId <- maybe randomXContactId pure xContactId_
          connId <- withAgent $ \a -> joinConnection a cReq $ directMessage (XContact profile $ Just xContactId)
          conn <- withStore' $ \db -> createConnReqConnection db userId connId cReqHash xContactId
          toView $ CRNewContactConnection conn
          pure CRSentInvitation
    contactMember :: Contact -> [GroupMember] -> Maybe GroupMember
    contactMember Contact {contactId} =
      find $ \GroupMember {memberContactId = cId, memberStatus = s} ->
        cId == Just contactId && s /= GSMemRemoved && s /= GSMemLeft
    checkSndFile :: FilePath -> m (Integer, Integer)
    checkSndFile f = do
      fsFilePath <- toFSFilePath f
      unlessM (doesFileExist fsFilePath) . throwChatError $ CEFileNotFound f
      (,) <$> getFileSize fsFilePath <*> asks (fileChunkSize . config)
    updateProfile :: User -> Profile -> m ChatResponse
    updateProfile user@User {profile = p} p'@Profile {displayName}
      | p' == p = pure CRUserProfileNoChange
      | otherwise = do
        withStore $ \db -> updateUserProfile db user p'
        let user' = (user :: User) {localDisplayName = displayName, profile = p'}
        asks currentUser >>= atomically . (`writeTVar` Just user')
        contacts <- filter isReady <$> withStore' (`getUserContacts` user)
        withChatLock . procCmd $ do
          forM_ contacts $ \ct ->
            void (sendDirectContactMessage ct $ XInfo p') `catchError` (toView . CRChatError)
          pure $ CRUserProfileUpdated p p'
    isReady :: Contact -> Bool
    isReady ct =
      let s = connStatus $ activeConn (ct :: Contact)
       in s == ConnReady || s == ConnSndReady
    -- perform an action only if filesFolder is set (i.e. on mobile devices)
    withFilesFolder :: (FilePath -> m ()) -> m ()
    withFilesFolder action = asks filesFolder >>= readTVarIO >>= mapM_ action
    deleteFile :: FilePath -> CIFileInfo -> m ()
    deleteFile filesFolder CIFileInfo {filePath} =
      forM_ filePath $ \fPath -> do
        let fsFilePath = filesFolder <> "/" <> fPath
        removeFile fsFilePath `E.catch` \(_ :: E.SomeException) ->
          removePathForcibly fsFilePath `E.catch` \(_ :: E.SomeException) -> pure ()
    cancelFile :: User -> CIFileInfo -> m ()
    cancelFile user CIFileInfo {fileId, fileStatus = (AFS dir status)} =
      unless (ciFileEnded status) $
        case dir of
          SMDSnd -> do
            (ftm@FileTransferMeta {cancelled}, fts) <- withStore (\db -> getSndFileTransfer db user fileId)
            unless cancelled $ cancelSndFile user ftm fts
          SMDRcv -> do
            ft@RcvFileTransfer {cancelled} <- withStore (\db -> getRcvFileTransfer db user fileId)
            unless cancelled $ cancelRcvFileTransfer user ft
    withCurrentCall :: ContactId -> (UserId -> Contact -> Call -> m (Maybe Call)) -> m ChatResponse
    withCurrentCall ctId action = withUser $ \User {userId} -> do
      ct <- withStore $ \db -> getContact db userId ctId
      calls <- asks currentCalls
      withChatLock $
        atomically (TM.lookup ctId calls) >>= \case
          Nothing -> throwChatError CENoCurrentCall
          Just call@Call {contactId}
            | ctId == contactId -> do
              call_ <- action userId ct call
              atomically $ case call_ of
                Just call' -> TM.insert ctId call' calls
                _ -> TM.delete ctId calls
              pure CRCmdOk
            | otherwise -> throwChatError $ CECallContact contactId
    forwardFile :: ChatName -> FileTransferId -> (ChatName -> FilePath -> ChatCommand) -> m ChatResponse
    forwardFile chatName fileId sendCommand = withUser $ \user -> do
      withStore (\db -> getFileTransfer db user fileId) >>= \case
        FTRcv RcvFileTransfer {fileStatus = RFSComplete RcvFileInfo {filePath}} -> forward filePath
        FTSnd {fileTransferMeta = FileTransferMeta {filePath}} -> forward filePath
        _ -> throwChatError CEFileNotReceived {fileId}
      where
        forward = processChatCommand . sendCommand chatName

updateCallItemStatus :: ChatMonad m => UserId -> Contact -> Call -> WebRTCCallStatus -> Maybe MessageId -> m ()
updateCallItemStatus userId ct Call {chatItemId} receivedStatus msgId_ = do
  aciContent_ <- callStatusItemContent userId ct chatItemId receivedStatus
  forM_ aciContent_ $ \aciContent -> updateDirectChatItemView userId ct chatItemId aciContent msgId_

updateDirectChatItemView :: ChatMonad m => UserId -> Contact -> ChatItemId -> ACIContent -> Maybe MessageId -> m ()
updateDirectChatItemView userId ct@Contact {contactId} chatItemId (ACIContent msgDir ciContent) msgId_ = do
  updCi <- withStore $ \db -> updateDirectChatItem db userId contactId chatItemId ciContent msgId_
  toView . CRChatItemUpdated $ AChatItem SCTDirect msgDir (DirectChat ct) updCi

callStatusItemContent :: ChatMonad m => UserId -> Contact -> ChatItemId -> WebRTCCallStatus -> m (Maybe ACIContent)
callStatusItemContent userId Contact {contactId} chatItemId receivedStatus = do
  CChatItem msgDir ChatItem {meta = CIMeta {updatedAt}, content} <-
    withStore $ \db -> getDirectChatItem db userId contactId chatItemId
  ts <- liftIO getCurrentTime
  let callDuration :: Int = nominalDiffTimeToSeconds (ts `diffUTCTime` updatedAt) `div'` 1
      callStatus = case content of
        CISndCall st _ -> Just st
        CIRcvCall st _ -> Just st
        _ -> Nothing
      newState_ = case (callStatus, receivedStatus) of
        (Just CISCallProgress, WCSConnected) -> Nothing -- if call in-progress received connected -> no change
        (Just CISCallProgress, WCSDisconnected) -> Just (CISCallEnded, callDuration) -- calculate in-progress duration
        (Just CISCallProgress, WCSFailed) -> Just (CISCallEnded, callDuration) -- whether call disconnected or failed
        (Just CISCallPending, WCSDisconnected) -> Just (CISCallMissed, 0)
        (Just CISCallEnded, _) -> Nothing -- if call already ended or failed -> no change
        (Just CISCallError, _) -> Nothing
        (Just _, WCSConnecting) -> Just (CISCallNegotiated, 0)
        (Just _, WCSConnected) -> Just (CISCallProgress, 0) -- if call ended that was never connected, duration = 0
        (Just _, WCSDisconnected) -> Just (CISCallEnded, 0)
        (Just _, WCSFailed) -> Just (CISCallError, 0)
        (Nothing, _) -> Nothing -- some other content - we should never get here, but no exception is thrown
  pure $ aciContent msgDir <$> newState_
  where
    aciContent :: forall d. SMsgDirection d -> (CICallStatus, Int) -> ACIContent
    aciContent msgDir (callStatus', duration) = case msgDir of
      SMDSnd -> ACIContent SMDSnd $ CISndCall callStatus' duration
      SMDRcv -> ACIContent SMDRcv $ CIRcvCall callStatus' duration

-- mobile clients use file paths relative to app directory (e.g. for the reason ios app directory changes on updates),
-- so we have to differentiate between the file path stored in db and communicated with frontend, and the file path
-- used during file transfer for actual operations with file system
toFSFilePath :: ChatMonad m => FilePath -> m FilePath
toFSFilePath f =
  maybe f (<> "/" <> f) <$> (readTVarIO =<< asks filesFolder)

acceptFileReceive :: forall m. ChatMonad m => User -> RcvFileTransfer -> Maybe FilePath -> m AChatItem
acceptFileReceive user@User {userId} RcvFileTransfer {fileId, fileInvitation = FileInvitation {fileName = fName, fileConnReq}, fileStatus, grpMemberId} filePath_ = do
  unless (fileStatus == RFSNew) $ case fileStatus of
    RFSCancelled _ -> throwChatError $ CEFileCancelled fName
    _ -> throwChatError $ CEFileAlreadyReceiving fName
  case fileConnReq of
    -- direct file protocol
    Just connReq ->
      tryError (withAgent $ \a -> joinConnection a connReq . directMessage $ XFileAcpt fName) >>= \case
        Right agentConnId -> do
          filePath <- getRcvFilePath filePath_ fName
          withStore $ \db -> acceptRcvFileTransfer db user fileId agentConnId ConnJoined filePath
        Left e -> throwError e
    -- group file protocol
    Nothing ->
      case grpMemberId of
        Nothing -> throwChatError $ CEFileInternal "group member not found for file transfer"
        Just memId -> do
          (GroupInfo {groupId}, GroupMember {activeConn}) <- withStore $ \db -> getGroupAndMember db user memId
          case activeConn of
            Just conn -> do
              sharedMsgId <- withStore $ \db -> getSharedMsgIdByFileId db userId fileId
              (agentConnId, fileInvConnReq) <- withAgent (`createConnection` SCMInvitation)
              filePath <- getRcvFilePath filePath_ fName
              ci <- withStore $ \db -> acceptRcvFileTransfer db user fileId agentConnId ConnNew filePath
              void $ sendDirectMessage conn (XFileAcptInv sharedMsgId fileInvConnReq fName) (GroupId groupId)
              pure ci
            _ -> throwChatError $ CEFileInternal "member connection not active"
  where
    getRcvFilePath :: Maybe FilePath -> String -> m FilePath
    getRcvFilePath fPath_ fn = case fPath_ of
      Nothing ->
        asks filesFolder >>= readTVarIO >>= \case
          Nothing -> do
            dir <- (`combine` "Downloads") <$> getHomeDirectory
            ifM (doesDirectoryExist dir) (pure dir) getTemporaryDirectory
              >>= (`uniqueCombine` fn)
              >>= createEmptyFile
          Just filesFolder ->
            filesFolder `uniqueCombine` fn
              >>= createEmptyFile
              >>= pure <$> takeFileName
      Just fPath ->
        ifM
          (doesDirectoryExist fPath)
          (fPath `uniqueCombine` fn >>= createEmptyFile)
          $ ifM
            (doesFileExist fPath)
            (throwChatError $ CEFileAlreadyExists fPath)
            (createEmptyFile fPath)
      where
        createEmptyFile :: FilePath -> m FilePath
        createEmptyFile fPath = emptyFile fPath `E.catch` (throwChatError . CEFileWrite fPath . (show :: E.SomeException -> String))
        emptyFile :: FilePath -> m FilePath
        emptyFile fPath = do
          h <- getFileHandle fileId fPath rcvFiles AppendMode
          liftIO $ B.hPut h "" >> hFlush h
          pure fPath
        uniqueCombine :: FilePath -> String -> m FilePath
        uniqueCombine filePath fileName = tryCombine (0 :: Int)
          where
            tryCombine n =
              let (name, ext) = splitExtensions fileName
                  suffix = if n == 0 then "" else "_" <> show n
                  f = filePath `combine` (name <> suffix <> ext)
               in ifM (doesFileExist f) (tryCombine $ n + 1) (pure f)

acceptContactRequest :: ChatMonad m => User -> UserContactRequest -> m Contact
acceptContactRequest User {userId, profile} UserContactRequest {agentInvitationId = AgentInvId invId, localDisplayName = cName, profileId, profile = p, userContactLinkId, xContactId} = do
  connId <- withAgent $ \a -> acceptContact a invId . directMessage $ XInfo profile
  withStore' $ \db -> createAcceptedContact db userId connId cName profileId p userContactLinkId xContactId

agentSubscriber :: (MonadUnliftIO m, MonadReader ChatController m) => User -> Bool -> m ()
agentSubscriber user subConns = do
  q <- asks $ subQ . smpAgent
  l <- asks chatLock
  when subConns $ subscribeUserConnections subscribeConnection user
  forever $ do
    (_, connId, msg) <- atomically $ readTBQueue q
    u <- readTVarIO =<< asks currentUser
    withLock l . void . runExceptT $
      processAgentMessage u connId msg `catchError` (toView . CRChatError)

subscribeUserConnections ::
  (MonadUnliftIO m, MonadReader ChatController m) =>
  (forall m'. ChatMonad m' => AgentClient -> ConnId -> ExceptT AgentErrorType m' ()) ->
  User ->
  m ()
subscribeUserConnections agentSubscribe user@User {userId} = do
  n <- asks $ subscriptionConcurrency . config
  ce <- asks $ subscriptionEvents . config
  void . runExceptT $ do
    catchErr $ subscribeContacts n ce
    catchErr $ subscribeUserContactLink n
    catchErr $ subscribeGroups n ce
    catchErr $ subscribeFiles n
    catchErr $ subscribePendingConnections n
  where
    catchErr a = a `catchError` \_ -> pure ()
    subscribeContacts n ce = do
      contacts <- withStore' (`getUserContacts` user)
      toView . CRContactSubSummary =<< pooledForConcurrentlyN n contacts (\ct -> ContactSubStatus ct <$> subscribeContact ce ct)
    subscribeContact ce ct =
      (subscribe (contactConnId ct) $> Nothing)
        `catchError` (\e -> when ce (toView $ CRContactSubError ct e) $> Just e)
    subscribeGroups n ce = do
      groups <- withStore' (`getUserGroups` user)
      toView . CRMemberSubErrors . mconcat =<< forM groups (subscribeGroup n ce)
    subscribeGroup n ce (Group g@GroupInfo {membership} members) = do
      let connectedMembers = mapMaybe (\m -> (m,) <$> memberConnId m) members
      if memberStatus membership == GSMemInvited
        then do
          toView $ CRGroupInvitation g
          pure []
        else
          if null connectedMembers
            then do
              if memberActive membership
                then toView $ CRGroupEmpty g
                else toView $ CRGroupRemoved g
              pure []
            else do
              ms <- pooledForConcurrentlyN n connectedMembers $ \(m@GroupMember {localDisplayName = c}, cId) ->
                (m,) <$> ((subscribe cId $> Nothing) `catchError` (\e -> when ce (toView $ CRMemberSubError g c e) $> Just e))
              toView $ CRGroupSubscribed g
              pure $ mapMaybe (\(m, e) -> (Just . MemberSubError m) =<< e) ms
    subscribeFiles n = do
      sndFileTransfers <- withStore' (`getLiveSndFileTransfers` user)
      pooledForConcurrentlyN_ n sndFileTransfers $ \sft -> subscribeSndFile sft
      rcvFileTransfers <- withStore' (`getLiveRcvFileTransfers` user)
      pooledForConcurrentlyN_ n rcvFileTransfers $ \rft -> subscribeRcvFile rft
      where
        subscribeSndFile ft@SndFileTransfer {fileId, fileStatus, agentConnId = AgentConnId cId} = do
          subscribe cId `catchError` (toView . CRSndFileSubError ft)
          void . forkIO $ do
            threadDelay 1000000
            l <- asks chatLock
            a <- asks smpAgent
            when (fileStatus == FSConnected) . unlessM (isFileActive fileId sndFiles) $
              withAgentLock a . withLock l $
                sendFileChunk user ft
        subscribeRcvFile ft@RcvFileTransfer {fileStatus} =
          case fileStatus of
            RFSAccepted fInfo -> resume fInfo
            RFSConnected fInfo -> resume fInfo
            _ -> pure ()
          where
            resume RcvFileInfo {agentConnId = AgentConnId cId} =
              subscribe cId `catchError` (toView . CRRcvFileSubError ft)
    subscribePendingConnections n = do
      cs <- withStore' (`getPendingConnections` user)
      summary <- pooledForConcurrentlyN n cs $ \Connection {agentConnId = acId@(AgentConnId cId)} ->
        PendingSubStatus acId <$> ((subscribe cId $> Nothing) `catchError` (pure . Just))
      toView $ CRPendingSubSummary summary
    subscribeUserContactLink n = do
      cs <- withStore (`getUserContactLinkConnections` userId)
      (subscribeConns n cs >> toView CRUserContactLinkSubscribed)
        `catchError` (toView . CRUserContactLinkSubError)
    subscribe cId = withAgent (`agentSubscribe` cId)
    subscribeConns n conns =
      withAgent $ \a ->
        pooledForConcurrentlyN_ n conns $ \c -> agentSubscribe a (aConnId c)

processAgentMessage :: forall m. ChatMonad m => Maybe User -> ConnId -> ACommand 'Agent -> m ()
processAgentMessage Nothing _ _ = throwChatError CENoActiveUser
processAgentMessage (Just User {userId}) "" agentMessage = case agentMessage of
  DOWN srv conns -> serverEvent srv conns CRContactsDisconnected "disconnected"
  UP srv conns -> serverEvent srv conns CRContactsSubscribed "connected"
  SUSPENDED -> toView CRChatSuspended
  _ -> pure ()
  where
    serverEvent srv@SMP.ProtocolServer {host, port} conns event str = do
      cs <- withStore' $ \db -> getConnectionsContacts db userId conns
      toView $ event srv cs
      showToast ("server " <> str) (safeDecodeUtf8 . strEncode $ SrvLoc host port)
processAgentMessage (Just user@User {userId, profile}) agentConnId agentMessage =
  (withStore (\db -> getConnectionEntity db user agentConnId) >>= updateConnStatus) >>= \case
    RcvDirectMsgConnection conn contact_ ->
      processDirectMessage agentMessage conn contact_
    RcvGroupMsgConnection conn gInfo m ->
      processGroupMessage agentMessage conn gInfo m
    RcvFileConnection conn ft ->
      processRcvFileConn agentMessage conn ft
    SndFileConnection conn ft ->
      processSndFileConn agentMessage conn ft
    UserContactConnection conn uc ->
      processUserContactRequest agentMessage conn uc
  where
    updateConnStatus :: ConnectionEntity -> m ConnectionEntity
    updateConnStatus acEntity = case agentMsgConnStatus agentMessage of
      Just connStatus -> do
        let conn = (entityConnection acEntity) {connStatus}
        withStore' $ \db -> updateConnectionStatus db conn connStatus
        pure $ updateEntityConnStatus acEntity connStatus
      Nothing -> pure acEntity

    isMember :: MemberId -> GroupInfo -> [GroupMember] -> Bool
    isMember memId GroupInfo {membership} members =
      sameMemberId memId membership || isJust (find (sameMemberId memId) members)

    agentMsgConnStatus :: ACommand 'Agent -> Maybe ConnStatus
    agentMsgConnStatus = \case
      CONF {} -> Just ConnRequested
      INFO _ -> Just ConnSndReady
      CON -> Just ConnReady
      _ -> Nothing

    processDirectMessage :: ACommand 'Agent -> Connection -> Maybe Contact -> m ()
    processDirectMessage agentMsg conn@Connection {connId, viaUserContactLink} = \case
      Nothing -> case agentMsg of
        CONF confId connInfo -> do
          saveConnInfo conn connInfo
          allowAgentConnection conn confId $ XInfo profile
        INFO connInfo ->
          saveConnInfo conn connInfo
        MSG meta _msgFlags msgBody -> do
          _ <- saveRcvMSG conn (ConnectionId connId) meta msgBody
          withAckMessage agentConnId meta $ pure ()
          ackMsgDeliveryEvent conn meta
        SENT msgId ->
          -- ? updateDirectChatItemStatus
          sentMsgDeliveryEvent conn msgId
        MERR _ err -> toView . CRChatError $ ChatErrorAgent err -- ? updateDirectChatItemStatus
        ERR err -> toView . CRChatError $ ChatErrorAgent err
        -- TODO add debugging output
        _ -> pure ()
      Just ct@Contact {localDisplayName = c, contactId} -> case agentMsg of
        MSG msgMeta _msgFlags msgBody -> do
          msg@RcvMessage {chatMsgEvent} <- saveRcvMSG conn (ConnectionId connId) msgMeta msgBody
          withAckMessage agentConnId msgMeta $
            case chatMsgEvent of
              XMsgNew mc -> newContentMessage ct mc msg msgMeta
              XMsgUpdate sharedMsgId mContent -> messageUpdate ct sharedMsgId mContent msg msgMeta
              XMsgDel sharedMsgId -> messageDelete ct sharedMsgId msg msgMeta
              -- TODO discontinue XFile
              XFile fInv -> processFileInvitation' ct fInv msg msgMeta
              XFileCancel sharedMsgId -> xFileCancel ct sharedMsgId msgMeta
              XInfo p -> xInfo ct p
              XGrpInv gInv -> processGroupInvitation ct gInv
              XInfoProbe probe -> xInfoProbe ct probe
              XInfoProbeCheck probeHash -> xInfoProbeCheck ct probeHash
              XInfoProbeOk probe -> xInfoProbeOk ct probe
              XCallInv callId invitation -> xCallInv ct callId invitation msg msgMeta
              XCallOffer callId offer -> xCallOffer ct callId offer msg msgMeta
              XCallAnswer callId answer -> xCallAnswer ct callId answer msg msgMeta
              XCallExtra callId extraInfo -> xCallExtra ct callId extraInfo msg msgMeta
              XCallEnd callId -> xCallEnd ct callId msg msgMeta
              _ -> pure ()
          ackMsgDeliveryEvent conn msgMeta
        CONF confId connInfo -> do
          -- confirming direct connection with a member
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XGrpMemInfo _memId _memProfile -> do
              -- TODO check member ID
              -- TODO update member profile
              allowAgentConnection conn confId XOk
            _ -> messageError "CONF from member must have x.grp.mem.info"
        INFO connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XGrpMemInfo _memId _memProfile -> do
              -- TODO check member ID
              -- TODO update member profile
              pure ()
            XInfo _profile -> do
              -- TODO update contact profile
              pure ()
            XOk -> pure ()
            _ -> messageError "INFO for existing contact must have x.grp.mem.info, x.info or x.ok"
        CON ->
          withStore' (\db -> getViaGroupMember db user ct) >>= \case
            Nothing -> do
              toView $ CRContactConnected ct
              setActive $ ActiveC c
              showToast (c <> "> ") "connected"
              forM_ viaUserContactLink $ \userContactLinkId -> do
                withStore' (\db -> getUserContactLinkById db userId userContactLinkId) >>= \case
                  Just (_, True, Just mc) -> do
                    msg <- sendDirectContactMessage ct (XMsgNew $ MCSimple (ExtMsgContent mc Nothing))
                    ci <- saveSndChatItem user (CDDirectSnd ct) msg (CISndMsgContent mc) Nothing Nothing
                    toView . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat ct) ci
                  _ -> pure ()
            Just (gInfo, m@GroupMember {activeConn}) -> do
              when (maybe False ((== ConnReady) . connStatus) activeConn) $ do
                notifyMemberConnected gInfo m
                when (memberCategory m == GCPreMember) $ probeMatchingContacts ct
        SENT msgId -> do
          sentMsgDeliveryEvent conn msgId
          withStore' (\db -> getDirectChatItemByAgentMsgId db userId contactId connId msgId) >>= \case
            Just (CChatItem SMDSnd ci) -> do
              chatItem <- withStore $ \db -> updateDirectChatItemStatus db userId contactId (chatItemId' ci) CISSndSent
              toView $ CRChatItemStatusUpdated (AChatItem SCTDirect SMDSnd (DirectChat ct) chatItem)
            _ -> pure ()
        END -> do
          toView $ CRContactAnotherClient ct
          showToast (c <> "> ") "connected to another client"
          unsetActive $ ActiveC c
        -- TODO print errors
        MERR msgId err -> do
          chatItemId_ <- withStore' $ \db -> getChatItemIdByAgentMsgId db connId msgId
          case chatItemId_ of
            Nothing -> pure ()
            Just chatItemId -> do
              chatItem <- withStore $ \db -> updateDirectChatItemStatus db userId contactId chatItemId (agentErrToItemStatus err)
              toView $ CRChatItemStatusUpdated (AChatItem SCTDirect SMDSnd (DirectChat ct) chatItem)
        ERR err -> toView . CRChatError $ ChatErrorAgent err
        -- TODO add debugging output
        _ -> pure ()

    processGroupMessage :: ACommand 'Agent -> Connection -> GroupInfo -> GroupMember -> m ()
    processGroupMessage agentMsg conn gInfo@GroupInfo {groupId, localDisplayName = gName, membership} m = case agentMsg of
      CONF confId connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case memberCategory m of
          GCInviteeMember ->
            case chatMsgEvent of
              XGrpAcpt memId
                | sameMemberId memId m -> do
                  withStore' $ \db -> updateGroupMemberStatus db userId m GSMemAccepted
                  allowAgentConnection conn confId XOk
                | otherwise -> messageError "x.grp.acpt: memberId is different from expected"
              _ -> messageError "CONF from invited member must have x.grp.acpt"
          _ ->
            case chatMsgEvent of
              XGrpMemInfo memId _memProfile
                | sameMemberId memId m -> do
                  -- TODO update member profile
                  allowAgentConnection conn confId $ XGrpMemInfo (memberId (membership :: GroupMember)) profile
                | otherwise -> messageError "x.grp.mem.info: memberId is different from expected"
              _ -> messageError "CONF from member must have x.grp.mem.info"
      INFO connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case chatMsgEvent of
          XGrpMemInfo memId _memProfile
            | sameMemberId memId m -> do
              -- TODO update member profile
              pure ()
            | otherwise -> messageError "x.grp.mem.info: memberId is different from expected"
          XOk -> pure ()
          _ -> messageError "INFO from member must have x.grp.mem.info"
        pure ()
      CON -> do
        members <- withStore' $ \db -> getGroupMembers db user gInfo
        withStore' $ \db -> do
          updateGroupMemberStatus db userId m GSMemConnected
          unless (memberActive membership) $
            updateGroupMemberStatus db userId membership GSMemConnected
        sendPendingGroupMessages m conn
        case memberCategory m of
          GCHostMember -> do
            toView $ CRUserJoinedGroup gInfo
            setActive $ ActiveG gName
            showToast ("#" <> gName) "you are connected to group"
          GCInviteeMember -> do
            toView $ CRJoinedGroupMember gInfo m
            setActive $ ActiveG gName
            showToast ("#" <> gName) $ "member " <> localDisplayName (m :: GroupMember) <> " is connected"
            intros <- withStore' $ \db -> createIntroductions db members m
            void . sendGroupMessage gInfo members . XGrpMemNew $ memberInfo m
            forM_ intros $ \intro@GroupMemberIntro {introId} -> do
              void $ sendDirectMessage conn (XGrpMemIntro . memberInfo $ reMember intro) (GroupId groupId)
              withStore' $ \db -> updateIntroStatus db introId GMIntroSent
          _ -> do
            -- TODO send probe and decide whether to use existing contact connection or the new contact connection
            -- TODO notify member who forwarded introduction - question - where it is stored? There is via_contact but probably there should be via_member in group_members table
            withStore' (\db -> getViaGroupContact db user m) >>= \case
              Nothing -> do
                notifyMemberConnected gInfo m
                messageError "implementation error: connected member does not have contact"
              Just ct@Contact {activeConn = Connection {connStatus}} ->
                when (connStatus == ConnReady) $ do
                  notifyMemberConnected gInfo m
                  when (memberCategory m == GCPreMember) $ probeMatchingContacts ct
      MSG msgMeta _msgFlags msgBody -> do
        msg@RcvMessage {chatMsgEvent} <- saveRcvMSG conn (GroupId groupId) msgMeta msgBody
        withAckMessage agentConnId msgMeta $
          case chatMsgEvent of
            XMsgNew mc -> newGroupContentMessage gInfo m mc msg msgMeta
            XMsgUpdate sharedMsgId mContent -> groupMessageUpdate gInfo m sharedMsgId mContent msg
            XMsgDel sharedMsgId -> groupMessageDelete gInfo m sharedMsgId msg
            -- TODO discontinue XFile
            XFile fInv -> processGroupFileInvitation' gInfo m fInv msg msgMeta
            XFileCancel sharedMsgId -> xFileCancelGroup gInfo m sharedMsgId msgMeta
            XFileAcptInv sharedMsgId fileConnReq fName -> xFileAcptInvGroup gInfo m sharedMsgId fileConnReq fName msgMeta
            XGrpMemNew memInfo -> xGrpMemNew gInfo m memInfo
            XGrpMemIntro memInfo -> xGrpMemIntro conn gInfo m memInfo
            XGrpMemInv memId introInv -> xGrpMemInv gInfo m memId introInv
            XGrpMemFwd memInfo introInv -> xGrpMemFwd gInfo m memInfo introInv
            XGrpMemDel memId -> xGrpMemDel gInfo m memId
            XGrpLeave -> xGrpLeave gInfo m
            XGrpDel -> xGrpDel gInfo m
            _ -> messageError $ "unsupported message: " <> T.pack (show chatMsgEvent)
        ackMsgDeliveryEvent conn msgMeta
      SENT msgId ->
        sentMsgDeliveryEvent conn msgId
      MERR _ err -> toView . CRChatError $ ChatErrorAgent err
      ERR err -> toView . CRChatError $ ChatErrorAgent err
      -- TODO add debugging output
      _ -> pure ()

    processSndFileConn :: ACommand 'Agent -> Connection -> SndFileTransfer -> m ()
    processSndFileConn agentMsg conn ft@SndFileTransfer {fileId, fileName, fileStatus} =
      case agentMsg of
        -- SMP CONF for SndFileConnection happens for direct file protocol
        -- when recipient of the file "joins" connection created by the sender
        CONF confId connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            -- TODO save XFileAcpt message
            XFileAcpt name
              | name == fileName -> do
                withStore' $ \db -> updateSndFileStatus db ft FSAccepted
                allowAgentConnection conn confId XOk
              | otherwise -> messageError "x.file.acpt: fileName is different from expected"
            _ -> messageError "CONF from file connection must have x.file.acpt"
        CON -> do
          ci <- withStore $ \db -> do
            liftIO $ updateSndFileStatus db ft FSConnected
            updateDirectCIFileStatus db user fileId CIFSSndTransfer
          toView $ CRSndFileStart ci ft
          sendFileChunk user ft
        SENT msgId -> do
          withStore' $ \db -> updateSndFileChunkSent db ft msgId
          unless (fileStatus == FSCancelled) $ sendFileChunk user ft
        MERR _ err -> do
          cancelSndFileTransfer ft
          case err of
            SMP SMP.AUTH -> unless (fileStatus == FSCancelled) $ do
              ci <- withStore $ \db -> getChatItemByFileId db user fileId
              toView $ CRSndFileRcvCancelled ci ft
            _ -> throwChatError $ CEFileSend fileId err
        MSG meta _ _ ->
          withAckMessage agentConnId meta $ pure ()
        ERR err -> toView . CRChatError $ ChatErrorAgent err
        -- TODO add debugging output
        _ -> pure ()

    processRcvFileConn :: ACommand 'Agent -> Connection -> RcvFileTransfer -> m ()
    processRcvFileConn agentMsg conn ft@RcvFileTransfer {fileId, chunkSize, cancelled} =
      case agentMsg of
        -- SMP CONF for RcvFileConnection happens for group file protocol
        -- when sender of the file "joins" connection created by the recipient
        -- (sender doesn't create connections for all group members)
        CONF confId connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XOk -> allowAgentConnection conn confId XOk
            _ -> pure ()
        CON -> do
          ci <- withStore $ \db -> do
            liftIO $ updateRcvFileStatus db ft FSConnected
            liftIO $ updateCIFileStatus db user fileId CIFSRcvTransfer
            getChatItemByFileId db user fileId
          toView $ CRRcvFileStart ci
        MSG meta@MsgMeta {recipient = (msgId, _), integrity} _ msgBody -> withAckMessage agentConnId meta $ do
          parseFileChunk msgBody >>= \case
            FileChunkCancel ->
              unless cancelled $ do
                cancelRcvFileTransfer user ft
                toView (CRRcvFileSndCancelled ft)
            FileChunk {chunkNo, chunkBytes = chunk} -> do
              case integrity of
                MsgOk -> pure ()
                MsgError MsgDuplicate -> pure () -- TODO remove once agent removes duplicates
                MsgError e ->
                  badRcvFileChunk ft $ "invalid file chunk number " <> show chunkNo <> ": " <> show e
              withStore' (\db -> createRcvFileChunk db ft chunkNo msgId) >>= \case
                RcvChunkOk ->
                  if B.length chunk /= fromInteger chunkSize
                    then badRcvFileChunk ft "incorrect chunk size"
                    else appendFileChunk ft chunkNo chunk
                RcvChunkFinal ->
                  if B.length chunk > fromInteger chunkSize
                    then badRcvFileChunk ft "incorrect chunk size"
                    else do
                      appendFileChunk ft chunkNo chunk
                      ci <- withStore $ \db -> do
                        liftIO $ do
                          updateRcvFileStatus db ft FSComplete
                          updateCIFileStatus db user fileId CIFSRcvComplete
                          deleteRcvFileChunks db ft
                        getChatItemByFileId db user fileId
                      toView $ CRRcvFileComplete ci
                      closeFileHandle fileId rcvFiles
                      withAgent (`deleteConnection` agentConnId)
                RcvChunkDuplicate -> pure ()
                RcvChunkError -> badRcvFileChunk ft $ "incorrect chunk number " <> show chunkNo
        MERR _ err -> toView . CRChatError $ ChatErrorAgent err
        ERR err -> toView . CRChatError $ ChatErrorAgent err
        -- TODO add debugging output
        _ -> pure ()

    processUserContactRequest :: ACommand 'Agent -> Connection -> UserContact -> m ()
    processUserContactRequest agentMsg _conn UserContact {userContactLinkId} = case agentMsg of
      REQ invId connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case chatMsgEvent of
          XContact p xContactId_ -> profileContactRequest invId p xContactId_
          XInfo p -> profileContactRequest invId p Nothing
          -- TODO show/log error, other events in contact request
          _ -> pure ()
      MERR _ err -> toView . CRChatError $ ChatErrorAgent err
      ERR err -> toView . CRChatError $ ChatErrorAgent err
      -- TODO add debugging output
      _ -> pure ()
      where
        profileContactRequest :: InvitationId -> Profile -> Maybe XContactId -> m ()
        profileContactRequest invId p xContactId_ = do
          withStore (\db -> createOrUpdateContactRequest db userId userContactLinkId invId p xContactId_) >>= \case
            CORContact contact -> toView $ CRContactRequestAlreadyAccepted contact
            CORRequest cReq@UserContactRequest {localDisplayName} -> do
              (_, autoAccept, _) <- withStore $ \db -> getUserContactLink db userId
              if autoAccept
                then acceptContactRequest user cReq >>= toView . CRAcceptingContactRequest
                else do
                  toView $ CRReceivedContactRequest cReq
                  showToast (localDisplayName <> "> ") "wants to connect to you"

    withAckMessage :: ConnId -> MsgMeta -> m () -> m ()
    withAckMessage cId MsgMeta {recipient = (msgId, _)} action =
      action `E.finally` withAgent (\a -> ackMessage a cId msgId `catchError` \_ -> pure ())

    ackMsgDeliveryEvent :: Connection -> MsgMeta -> m ()
    ackMsgDeliveryEvent Connection {connId} MsgMeta {recipient = (msgId, _)} =
      withStore $ \db -> createRcvMsgDeliveryEvent db connId msgId MDSRcvAcknowledged

    sentMsgDeliveryEvent :: Connection -> AgentMsgId -> m ()
    sentMsgDeliveryEvent Connection {connId} msgId =
      withStore $ \db -> createSndMsgDeliveryEvent db connId msgId MDSSndSent

    agentErrToItemStatus :: AgentErrorType -> CIStatus 'MDSnd
    agentErrToItemStatus (SMP AUTH) = CISSndErrorAuth
    agentErrToItemStatus err = CISSndError err

    badRcvFileChunk :: RcvFileTransfer -> String -> m ()
    badRcvFileChunk ft@RcvFileTransfer {cancelled} err =
      unless cancelled $ do
        cancelRcvFileTransfer user ft
        throwChatError $ CEFileRcvChunk err

    notifyMemberConnected :: GroupInfo -> GroupMember -> m ()
    notifyMemberConnected gInfo m@GroupMember {localDisplayName = c} = do
      toView $ CRConnectedToGroupMember gInfo m
      let g = groupName' gInfo
      setActive $ ActiveG g
      showToast ("#" <> g) $ "member " <> c <> " is connected"

    probeMatchingContacts :: Contact -> m ()
    probeMatchingContacts ct = do
      gVar <- asks idsDrg
      (probe, probeId) <- withStore $ \db -> createSentProbe db gVar userId ct
      void . sendDirectContactMessage ct $ XInfoProbe probe
      cs <- withStore' $ \db -> getMatchingContacts db userId ct
      let probeHash = ProbeHash $ C.sha256Hash (unProbe probe)
      forM_ cs $ \c -> sendProbeHash c probeHash probeId `catchError` const (pure ())
      where
        sendProbeHash :: Contact -> ProbeHash -> Int64 -> m ()
        sendProbeHash c probeHash probeId = do
          void . sendDirectContactMessage c $ XInfoProbeCheck probeHash
          withStore' $ \db -> createSentProbeHash db userId probeId c

    messageWarning :: Text -> m ()
    messageWarning = toView . CRMessageError "warning"

    messageError :: Text -> m ()
    messageError = toView . CRMessageError "error"

    newContentMessage :: Contact -> MsgContainer -> RcvMessage -> MsgMeta -> m ()
    newContentMessage ct@Contact {localDisplayName = c} mc msg msgMeta = do
      checkIntegrityCreateItem (CDDirectRcv ct) msgMeta
      let (ExtMsgContent content fileInvitation_) = mcExtMsgContent mc
      ciFile_ <- processFileInvitation fileInvitation_ $
        \fi chSize -> withStore' $ \db -> createRcvFileTransfer db userId ct fi chSize
      ci@ChatItem {formattedText} <- saveRcvChatItem user (CDDirectRcv ct) msg msgMeta (CIRcvMsgContent content) ciFile_
      toView . CRNewChatItem $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
      showMsgToast (c <> "> ") content formattedText
      setActive $ ActiveC c

    processFileInvitation :: Maybe FileInvitation -> (FileInvitation -> Integer -> m RcvFileTransfer) -> m (Maybe (CIFile 'MDRcv))
    processFileInvitation fileInvitation_ createRcvFileTransferF = case fileInvitation_ of
      Nothing -> pure Nothing
      Just fileInvitation@FileInvitation {fileName, fileSize} -> do
        chSize <- asks $ fileChunkSize . config
        RcvFileTransfer {fileId} <- createRcvFileTransferF fileInvitation chSize
        let ciFile = CIFile {fileId, fileName, fileSize, filePath = Nothing, fileStatus = CIFSRcvInvitation}
        pure $ Just ciFile

    messageUpdate :: Contact -> SharedMsgId -> MsgContent -> RcvMessage -> MsgMeta -> m ()
    messageUpdate ct@Contact {contactId, localDisplayName = c} sharedMsgId mc msg@RcvMessage {msgId} msgMeta = do
      checkIntegrityCreateItem (CDDirectRcv ct) msgMeta
      updateRcvChatItem `catchError` \e ->
        case e of
          (ChatErrorStore (SEChatItemSharedMsgIdNotFound _)) -> do
            -- This patches initial sharedMsgId into chat item when locally deleted chat item
            -- received an update from the sender, so that it can be referenced later (e.g. by broadcast delete).
            -- Chat item and update message which created it will have different sharedMsgId in this case...
            ci@ChatItem {formattedText} <- saveRcvChatItem' user (CDDirectRcv ct) msg (Just sharedMsgId) msgMeta (CIRcvMsgContent mc) Nothing
            toView . CRChatItemUpdated $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
            showMsgToast (c <> "> ") mc formattedText
            setActive $ ActiveC c
          _ -> throwError e
      where
        updateRcvChatItem = do
          CChatItem msgDir ChatItem {meta = CIMeta {itemId}} <- withStore $ \db -> getDirectChatItemBySharedMsgId db userId contactId sharedMsgId
          case msgDir of
            SMDRcv -> updateDirectChatItemView userId ct itemId (ACIContent SMDRcv $ CIRcvMsgContent mc) $ Just msgId
            SMDSnd -> messageError "x.msg.update: contact attempted invalid message update"

    messageDelete :: Contact -> SharedMsgId -> RcvMessage -> MsgMeta -> m ()
    messageDelete ct@Contact {contactId} sharedMsgId RcvMessage {msgId} msgMeta = do
      checkIntegrityCreateItem (CDDirectRcv ct) msgMeta
      deleteRcvChatItem `catchError` \e ->
        case e of
          (ChatErrorStore (SEChatItemSharedMsgIdNotFound sMsgId)) -> toView $ CRChatItemDeletedNotFound ct sMsgId
          _ -> throwError e
      where
        deleteRcvChatItem = do
          CChatItem msgDir deletedItem@ChatItem {meta = CIMeta {itemId}} <- withStore $ \db -> getDirectChatItemBySharedMsgId db userId contactId sharedMsgId
          case msgDir of
            SMDRcv -> do
              toCi <- withStore $ \db -> deleteDirectChatItemRcvBroadcast db userId ct itemId msgId
              toView $ CRChatItemDeleted (AChatItem SCTDirect SMDRcv (DirectChat ct) deletedItem) toCi
            SMDSnd -> messageError "x.msg.del: contact attempted invalid message delete"

    newGroupContentMessage :: GroupInfo -> GroupMember -> MsgContainer -> RcvMessage -> MsgMeta -> m ()
    newGroupContentMessage gInfo m@GroupMember {localDisplayName = c} mc msg msgMeta = do
      let (ExtMsgContent content fileInvitation_) = mcExtMsgContent mc
      ciFile_ <- processFileInvitation fileInvitation_ $
        \fi chSize -> withStore' $ \db -> createRcvGroupFileTransfer db userId m fi chSize
      ci@ChatItem {formattedText} <- saveRcvChatItem user (CDGroupRcv gInfo m) msg msgMeta (CIRcvMsgContent content) ciFile_
      groupMsgToView gInfo m ci msgMeta
      let g = groupName' gInfo
      showMsgToast ("#" <> g <> " " <> c <> "> ") content formattedText
      setActive $ ActiveG g

    groupMessageUpdate :: GroupInfo -> GroupMember -> SharedMsgId -> MsgContent -> RcvMessage -> m ()
    groupMessageUpdate gInfo@GroupInfo {groupId} GroupMember {memberId} sharedMsgId mc RcvMessage {msgId} = do
      CChatItem msgDir ChatItem {chatDir, meta = CIMeta {itemId}} <- withStore $ \db -> getGroupChatItemBySharedMsgId db user groupId sharedMsgId
      case (msgDir, chatDir) of
        (SMDRcv, CIGroupRcv m) ->
          if sameMemberId memberId m
            then do
              updCi <- withStore $ \db -> updateGroupChatItem db user groupId itemId (CIRcvMsgContent mc) msgId
              toView . CRChatItemUpdated $ AChatItem SCTGroup SMDRcv (GroupChat gInfo) updCi
            else messageError "x.msg.update: group member attempted to update a message of another member"
        (SMDSnd, _) -> messageError "x.msg.update: group member attempted invalid message update"

    groupMessageDelete :: GroupInfo -> GroupMember -> SharedMsgId -> RcvMessage -> m ()
    groupMessageDelete gInfo@GroupInfo {groupId} GroupMember {memberId} sharedMsgId RcvMessage {msgId} = do
      CChatItem msgDir deletedItem@ChatItem {chatDir, meta = CIMeta {itemId}} <- withStore $ \db -> getGroupChatItemBySharedMsgId db user groupId sharedMsgId
      case (msgDir, chatDir) of
        (SMDRcv, CIGroupRcv m) ->
          if sameMemberId memberId m
            then do
              toCi <- withStore $ \db -> deleteGroupChatItemRcvBroadcast db user gInfo itemId msgId
              toView $ CRChatItemDeleted (AChatItem SCTGroup SMDRcv (GroupChat gInfo) deletedItem) toCi
            else messageError "x.msg.del: group member attempted to delete a message of another member"
        (SMDSnd, _) -> messageError "x.msg.del: group member attempted invalid message delete"

    -- TODO remove once XFile is discontinued
    processFileInvitation' :: Contact -> FileInvitation -> RcvMessage -> MsgMeta -> m ()
    processFileInvitation' ct@Contact {localDisplayName = c} fInv@FileInvitation {fileName, fileSize} msg msgMeta = do
      checkIntegrityCreateItem (CDDirectRcv ct) msgMeta
      chSize <- asks $ fileChunkSize . config
      RcvFileTransfer {fileId} <- withStore' $ \db -> createRcvFileTransfer db userId ct fInv chSize
      let ciFile = Just $ CIFile {fileId, fileName, fileSize, filePath = Nothing, fileStatus = CIFSRcvInvitation}
      ci <- saveRcvChatItem user (CDDirectRcv ct) msg msgMeta (CIRcvMsgContent $ MCFile "") ciFile
      toView . CRNewChatItem $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
      showToast (c <> "> ") "wants to send a file"
      setActive $ ActiveC c

    -- TODO remove once XFile is discontinued
    processGroupFileInvitation' :: GroupInfo -> GroupMember -> FileInvitation -> RcvMessage -> MsgMeta -> m ()
    processGroupFileInvitation' gInfo m@GroupMember {localDisplayName = c} fInv@FileInvitation {fileName, fileSize} msg msgMeta = do
      chSize <- asks $ fileChunkSize . config
      RcvFileTransfer {fileId} <- withStore' $ \db -> createRcvGroupFileTransfer db userId m fInv chSize
      let ciFile = Just $ CIFile {fileId, fileName, fileSize, filePath = Nothing, fileStatus = CIFSRcvInvitation}
      ci <- saveRcvChatItem user (CDGroupRcv gInfo m) msg msgMeta (CIRcvMsgContent $ MCFile "") ciFile
      groupMsgToView gInfo m ci msgMeta
      let g = groupName' gInfo
      showToast ("#" <> g <> " " <> c <> "> ") "wants to send a file"
      setActive $ ActiveG g

    xFileCancel :: Contact -> SharedMsgId -> MsgMeta -> m ()
    xFileCancel ct@Contact {contactId} sharedMsgId msgMeta = do
      checkIntegrityCreateItem (CDDirectRcv ct) msgMeta
      fileId <- withStore $ \db -> getFileIdBySharedMsgId db userId contactId sharedMsgId
      ft@RcvFileTransfer {cancelled} <- withStore (\db -> getRcvFileTransfer db user fileId)
      unless cancelled $ do
        cancelRcvFileTransfer user ft
        toView $ CRRcvFileSndCancelled ft

    xFileCancelGroup :: GroupInfo -> GroupMember -> SharedMsgId -> MsgMeta -> m ()
    xFileCancelGroup g@GroupInfo {groupId} mem@GroupMember {memberId} sharedMsgId msgMeta = do
      checkIntegrityCreateItem (CDGroupRcv g mem) msgMeta
      fileId <- withStore $ \db -> getGroupFileIdBySharedMsgId db userId groupId sharedMsgId
      CChatItem msgDir ChatItem {chatDir} <- withStore $ \db -> getGroupChatItemBySharedMsgId db user groupId sharedMsgId
      case (msgDir, chatDir) of
        (SMDRcv, CIGroupRcv m) -> do
          if sameMemberId memberId m
            then do
              ft@RcvFileTransfer {cancelled} <- withStore (\db -> getRcvFileTransfer db user fileId)
              unless cancelled $ do
                cancelRcvFileTransfer user ft
                toView $ CRRcvFileSndCancelled ft
            else messageError "x.file.cancel: group member attempted to cancel file of another member"
        (SMDSnd, _) -> messageError "x.file.cancel: group member attempted invalid file cancel"

    xFileAcptInvGroup :: GroupInfo -> GroupMember -> SharedMsgId -> ConnReqInvitation -> String -> MsgMeta -> m ()
    xFileAcptInvGroup g@GroupInfo {groupId} m sharedMsgId fileConnReq fName msgMeta = do
      checkIntegrityCreateItem (CDGroupRcv g m) msgMeta
      fileId <- withStore $ \db -> getGroupFileIdBySharedMsgId db userId groupId sharedMsgId
      (FileTransferMeta {fileName, cancelled}, _) <- withStore (\db -> getSndFileTransfer db user fileId)
      unless cancelled $
        if fName == fileName
          then
            tryError (withAgent $ \a -> joinConnection a fileConnReq . directMessage $ XOk) >>= \case
              Right acId ->
                withStore' $ \db -> createSndGroupFileTransferConnection db userId fileId acId m
              Left e -> throwError e
          else messageError "x.file.acpt.inv: fileName is different from expected"

    groupMsgToView :: GroupInfo -> GroupMember -> ChatItem 'CTGroup 'MDRcv -> MsgMeta -> m ()
    groupMsgToView gInfo m ci msgMeta = do
      checkIntegrityCreateItem (CDGroupRcv gInfo m) msgMeta
      toView . CRNewChatItem $ AChatItem SCTGroup SMDRcv (GroupChat gInfo) ci

    processGroupInvitation :: Contact -> GroupInvitation -> m ()
    processGroupInvitation ct@Contact {localDisplayName = c} inv@(GroupInvitation (MemberIdRole fromMemId fromRole) (MemberIdRole memId memRole) _ _) = do
      when (fromRole < GRAdmin || fromRole < memRole) $ throwChatError (CEGroupContactRole c)
      when (fromMemId == memId) $ throwChatError CEGroupDuplicateMemberId
      gInfo@GroupInfo {localDisplayName = gName} <- withStore $ \db -> createGroupInvitation db user ct inv
      toView $ CRReceivedGroupInvitation gInfo ct memRole
      showToast ("#" <> gName <> " " <> c <> "> ") "invited you to join the group"

    checkIntegrityCreateItem :: forall c. ChatTypeI c => ChatDirection c 'MDRcv -> MsgMeta -> m ()
    checkIntegrityCreateItem cd MsgMeta {integrity, broker = (_, brokerTs)} = case integrity of
      MsgOk -> pure ()
      MsgError e -> case e of
        MsgSkipped {} -> createIntegrityErrorItem e
        _ -> toView $ CRMsgIntegrityError e
      where
        createIntegrityErrorItem e = do
          createdAt <- liftIO getCurrentTime
          let content = CIRcvIntegrityError e
          ciId <- withStore' $ \db -> createNewChatItemNoMsg db user cd content brokerTs createdAt
          ci <- liftIO $ mkChatItem cd ciId content Nothing Nothing Nothing brokerTs createdAt
          toView $ CRNewChatItem $ AChatItem (chatTypeI @c) SMDRcv (toChatInfo cd) ci

    xInfo :: Contact -> Profile -> m ()
    xInfo c@Contact {profile = p} p' = unless (p == p') $ do
      c' <- withStore $ \db -> updateContactProfile db userId c p'
      toView $ CRContactUpdated c c'

    xInfoProbe :: Contact -> Probe -> m ()
    xInfoProbe c2 probe = do
      r <- withStore' $ \db -> matchReceivedProbe db userId c2 probe
      forM_ r $ \c1 -> probeMatch c1 c2 probe

    xInfoProbeCheck :: Contact -> ProbeHash -> m ()
    xInfoProbeCheck c1 probeHash = do
      r <- withStore' $ \db -> matchReceivedProbeHash db userId c1 probeHash
      forM_ r . uncurry $ probeMatch c1

    probeMatch :: Contact -> Contact -> Probe -> m ()
    probeMatch c1@Contact {profile = p1} c2@Contact {profile = p2} probe =
      when (p1 == p2) $ do
        void . sendDirectContactMessage c1 $ XInfoProbeOk probe
        mergeContacts c1 c2

    xInfoProbeOk :: Contact -> Probe -> m ()
    xInfoProbeOk c1 probe = do
      r <- withStore' $ \db -> matchSentProbe db userId c1 probe
      forM_ r $ \c2 -> mergeContacts c1 c2

    -- to party accepting call
    xCallInv :: Contact -> CallId -> CallInvitation -> RcvMessage -> MsgMeta -> m ()
    xCallInv ct@Contact {contactId} callId CallInvitation {callType, callDhPubKey} msg msgMeta = do
      checkIntegrityCreateItem (CDDirectRcv ct) msgMeta
      dhKeyPair <- if encryptedCall callType then Just <$> liftIO C.generateKeyPair' else pure Nothing
      ci <- saveCallItem CISCallPending
      let sharedKey = C.Key . C.dhBytes' <$> (C.dh' <$> callDhPubKey <*> (snd <$> dhKeyPair))
          callState = CallInvitationReceived {peerCallType = callType, localDhPubKey = fst <$> dhKeyPair, sharedKey}
          call' = Call {contactId, callId, chatItemId = chatItemId' ci, callState}
      calls <- asks currentCalls
      -- theoretically, the new call invitation for the current contant can mark the in-progress call as ended
      -- (and replace it in ChatController)
      -- practically, this should not happen
      call_ <- atomically (TM.lookupInsert contactId call' calls)
      forM_ call_ $ \call -> updateCallItemStatus userId ct call WCSDisconnected Nothing
      toView . CRCallInvitation ct callType sharedKey $ chatItemTs' ci
      toView . CRNewChatItem $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
      where
        saveCallItem status = saveRcvChatItem user (CDDirectRcv ct) msg msgMeta (CIRcvCall status 0) Nothing

    -- to party initiating call
    xCallOffer :: Contact -> CallId -> CallOffer -> RcvMessage -> MsgMeta -> m ()
    xCallOffer ct callId CallOffer {callType, rtcSession, callDhPubKey} msg msgMeta = do
      msgCurrentCall ct callId "x.call.offer" msg msgMeta $
        \call -> case callState call of
          CallInvitationSent {localCallType, localDhPrivKey} -> do
            let sharedKey = C.Key . C.dhBytes' <$> (C.dh' <$> callDhPubKey <*> localDhPrivKey)
                callState' = CallOfferReceived {localCallType, peerCallType = callType, peerCallSession = rtcSession, sharedKey}
                askConfirmation = encryptedCall localCallType && not (encryptedCall callType)
            toView CRCallOffer {contact = ct, callType, offer = rtcSession, sharedKey, askConfirmation}
            pure (Just call {callState = callState'}, Just . ACIContent SMDSnd $ CISndCall CISCallAccepted 0)
          _ -> do
            msgCallStateError "x.call.offer" call
            pure (Just call, Nothing)

    -- to party accepting call
    xCallAnswer :: Contact -> CallId -> CallAnswer -> RcvMessage -> MsgMeta -> m ()
    xCallAnswer ct callId CallAnswer {rtcSession} msg msgMeta = do
      msgCurrentCall ct callId "x.call.answer" msg msgMeta $
        \call -> case callState call of
          CallOfferSent {localCallType, peerCallType, localCallSession, sharedKey} -> do
            let callState' = CallNegotiated {localCallType, peerCallType, localCallSession, peerCallSession = rtcSession, sharedKey}
            toView $ CRCallAnswer ct rtcSession
            pure (Just call {callState = callState'}, Just . ACIContent SMDRcv $ CIRcvCall CISCallNegotiated 0)
          _ -> do
            msgCallStateError "x.call.answer" call
            pure (Just call, Nothing)

    -- to any call party
    xCallExtra :: Contact -> CallId -> CallExtraInfo -> RcvMessage -> MsgMeta -> m ()
    xCallExtra ct callId CallExtraInfo {rtcExtraInfo} msg msgMeta = do
      msgCurrentCall ct callId "x.call.extra" msg msgMeta $
        \call -> case callState call of
          CallOfferReceived {localCallType, peerCallType, peerCallSession, sharedKey} -> do
            -- TODO update the list of ice servers in peerCallSession
            let callState' = CallOfferReceived {localCallType, peerCallType, peerCallSession, sharedKey}
            toView $ CRCallExtraInfo ct rtcExtraInfo
            pure (Just call {callState = callState'}, Nothing)
          CallNegotiated {localCallType, peerCallType, localCallSession, peerCallSession, sharedKey} -> do
            -- TODO update the list of ice servers in peerCallSession
            let callState' = CallNegotiated {localCallType, peerCallType, localCallSession, peerCallSession, sharedKey}
            toView $ CRCallExtraInfo ct rtcExtraInfo
            pure (Just call {callState = callState'}, Nothing)
          _ -> do
            msgCallStateError "x.call.extra" call
            pure (Just call, Nothing)

    -- to any call party
    xCallEnd :: Contact -> CallId -> RcvMessage -> MsgMeta -> m ()
    xCallEnd ct callId msg msgMeta =
      msgCurrentCall ct callId "x.call.end" msg msgMeta $ \Call {chatItemId} -> do
        toView $ CRCallEnded ct
        (Nothing,) <$> callStatusItemContent userId ct chatItemId WCSDisconnected

    msgCurrentCall :: Contact -> CallId -> Text -> RcvMessage -> MsgMeta -> (Call -> m (Maybe Call, Maybe ACIContent)) -> m ()
    msgCurrentCall ct@Contact {contactId = ctId'} callId' eventName RcvMessage {msgId} msgMeta action = do
      checkIntegrityCreateItem (CDDirectRcv ct) msgMeta
      calls <- asks currentCalls
      atomically (TM.lookup ctId' calls) >>= \case
        Nothing -> messageError $ eventName <> ": no current call"
        Just call@Call {contactId, callId, chatItemId}
          | contactId /= ctId' || callId /= callId' -> messageError $ eventName <> ": wrong contact or callId"
          | otherwise -> do
            (call_, aciContent_) <- action call
            atomically $ case call_ of
              Just call' -> TM.insert ctId' call' calls
              _ -> TM.delete ctId' calls
            forM_ aciContent_ $ \aciContent ->
              updateDirectChatItemView userId ct chatItemId aciContent $ Just msgId

    msgCallStateError :: Text -> Call -> m ()
    msgCallStateError eventName Call {callState} =
      messageError $ eventName <> ": wrong call state " <> T.pack (show $ callStateTag callState)

    mergeContacts :: Contact -> Contact -> m ()
    mergeContacts to from = do
      withStore' $ \db -> mergeContactRecords db userId to from
      toView $ CRContactsMerged to from

    saveConnInfo :: Connection -> ConnInfo -> m ()
    saveConnInfo activeConn connInfo = do
      ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
      case chatMsgEvent of
        XInfo p -> do
          ct <- withStore $ \db -> createDirectContact db userId activeConn p
          toView $ CRContactConnecting ct
        -- TODO show/log error, other events in SMP confirmation
        _ -> pure ()

    xGrpMemNew :: GroupInfo -> GroupMember -> MemberInfo -> m ()
    xGrpMemNew gInfo m memInfo@(MemberInfo memId _ _) = do
      members <- withStore' $ \db -> getGroupMembers db user gInfo
      unless (sameMemberId memId $ membership gInfo) $
        if isMember memId gInfo members
          then messageError "x.grp.mem.new error: member already exists"
          else do
            newMember <- withStore $ \db -> createNewGroupMember db user gInfo memInfo GCPostMember GSMemAnnounced
            toView $ CRJoinedGroupMemberConnecting gInfo m newMember

    xGrpMemIntro :: Connection -> GroupInfo -> GroupMember -> MemberInfo -> m ()
    xGrpMemIntro conn gInfo@GroupInfo {groupId} m memInfo@(MemberInfo memId _ _) = do
      case memberCategory m of
        GCHostMember -> do
          members <- withStore' $ \db -> getGroupMembers db user gInfo
          if isMember memId gInfo members
            then messageWarning "x.grp.mem.intro ignored: member already exists"
            else do
              (groupConnId, groupConnReq) <- withAgent (`createConnection` SCMInvitation)
              (directConnId, directConnReq) <- withAgent (`createConnection` SCMInvitation)
              newMember <- withStore $ \db -> createIntroReMember db user gInfo m memInfo groupConnId directConnId
              let msg = XGrpMemInv memId IntroInvitation {groupConnReq, directConnReq}
              void $ sendDirectMessage conn msg (GroupId groupId)
              withStore' $ \db -> updateGroupMemberStatus db userId newMember GSMemIntroInvited
        _ -> messageError "x.grp.mem.intro can be only sent by host member"

    xGrpMemInv :: GroupInfo -> GroupMember -> MemberId -> IntroInvitation -> m ()
    xGrpMemInv gInfo m memId introInv = do
      case memberCategory m of
        GCInviteeMember -> do
          members <- withStore' $ \db -> getGroupMembers db user gInfo
          case find (sameMemberId memId) members of
            Nothing -> messageError "x.grp.mem.inv error: referenced member does not exist"
            Just reMember -> do
              GroupMemberIntro {introId} <- withStore $ \db -> saveIntroInvitation db reMember m introInv
              void $ sendXGrpMemInv gInfo reMember (XGrpMemFwd (memberInfo m) introInv) introId
        _ -> messageError "x.grp.mem.inv can be only sent by invitee member"

    xGrpMemFwd :: GroupInfo -> GroupMember -> MemberInfo -> IntroInvitation -> m ()
    xGrpMemFwd gInfo@GroupInfo {membership} m memInfo@(MemberInfo memId _ _) introInv@IntroInvitation {groupConnReq, directConnReq} = do
      members <- withStore' $ \db -> getGroupMembers db user gInfo
      toMember <- case find (sameMemberId memId) members of
        -- TODO if the missed messages are correctly sent as soon as there is connection before anything else is sent
        -- the situation when member does not exist is an error
        -- member receiving x.grp.mem.fwd should have also received x.grp.mem.new prior to that.
        -- For now, this branch compensates for the lack of delayed message delivery.
        Nothing -> withStore $ \db -> createNewGroupMember db user gInfo memInfo GCPostMember GSMemAnnounced
        Just m' -> pure m'
      withStore' $ \db -> saveMemberInvitation db toMember introInv
      let msg = XGrpMemInfo (memberId (membership :: GroupMember)) profile
      groupConnId <- withAgent $ \a -> joinConnection a groupConnReq $ directMessage msg
      directConnId <- withAgent $ \a -> joinConnection a directConnReq $ directMessage msg
      withStore' $ \db -> createIntroToMemberContact db userId m toMember groupConnId directConnId

    xGrpMemDel :: GroupInfo -> GroupMember -> MemberId -> m ()
    xGrpMemDel gInfo@GroupInfo {membership} m memId = do
      members <- withStore' $ \db -> getGroupMembers db user gInfo
      if memberId (membership :: GroupMember) == memId
        then do
          mapM_ deleteMemberConnection members
          withStore' $ \db -> updateGroupMemberStatus db userId membership GSMemRemoved
          toView $ CRDeletedMemberUser gInfo m
        else case find (sameMemberId memId) members of
          Nothing -> messageError "x.grp.mem.del with unknown member ID"
          Just member -> do
            let mRole = memberRole (m :: GroupMember)
            if mRole < GRAdmin || mRole < memberRole (member :: GroupMember)
              then messageError "x.grp.mem.del with insufficient member permissions"
              else do
                deleteMemberConnection member
                withStore' $ \db -> updateGroupMemberStatus db userId member GSMemRemoved
                toView $ CRDeletedMember gInfo m member

    sameMemberId :: MemberId -> GroupMember -> Bool
    sameMemberId memId GroupMember {memberId} = memId == memberId

    xGrpLeave :: GroupInfo -> GroupMember -> m ()
    xGrpLeave gInfo m = do
      deleteMemberConnection m
      withStore' $ \db -> updateGroupMemberStatus db userId m GSMemLeft
      toView $ CRLeftMember gInfo m

    xGrpDel :: GroupInfo -> GroupMember -> m ()
    xGrpDel gInfo m@GroupMember {memberRole} = do
      when (memberRole /= GROwner) $ throwChatError CEGroupUserRole
      ms <- withStore' $ \db -> do
        members <- getGroupMembers db user gInfo
        updateGroupMemberStatus db userId (membership gInfo) GSMemGroupDeleted
        pure members
      mapM_ deleteMemberConnection ms
      toView $ CRGroupDeleted gInfo m

parseChatMessage :: ByteString -> Either ChatError ChatMessage
parseChatMessage = first (ChatError . CEInvalidChatMessage) . strDecode

sendFileChunk :: ChatMonad m => User -> SndFileTransfer -> m ()
sendFileChunk user ft@SndFileTransfer {fileId, fileStatus, agentConnId = AgentConnId acId} =
  unless (fileStatus == FSComplete || fileStatus == FSCancelled) $
    withStore' (`createSndFileChunk` ft) >>= \case
      Just chunkNo -> sendFileChunkNo ft chunkNo
      Nothing -> do
        ci <- withStore $ \db -> do
          liftIO $ updateSndFileStatus db ft FSComplete
          liftIO $ deleteSndFileChunks db ft
          updateDirectCIFileStatus db user fileId CIFSSndComplete
        toView $ CRSndFileComplete ci ft
        closeFileHandle fileId sndFiles
        withAgent (`deleteConnection` acId)

sendFileChunkNo :: ChatMonad m => SndFileTransfer -> Integer -> m ()
sendFileChunkNo ft@SndFileTransfer {agentConnId = AgentConnId acId} chunkNo = do
  chunkBytes <- readFileChunk ft chunkNo
  msgId <- withAgent $ \a -> sendMessage a acId SMP.noMsgFlags $ smpEncode FileChunk {chunkNo, chunkBytes}
  withStore' $ \db -> updateSndFileChunkMsg db ft chunkNo msgId

readFileChunk :: ChatMonad m => SndFileTransfer -> Integer -> m ByteString
readFileChunk SndFileTransfer {fileId, filePath, chunkSize} chunkNo = do
  fsFilePath <- toFSFilePath filePath
  read_ fsFilePath `E.catch` (throwChatError . CEFileRead filePath . (show :: E.SomeException -> String))
  where
    read_ fsFilePath = do
      h <- getFileHandle fileId fsFilePath sndFiles ReadMode
      pos <- hTell h
      let pos' = (chunkNo - 1) * chunkSize
      when (pos /= pos') $ hSeek h AbsoluteSeek pos'
      liftIO . B.hGet h $ fromInteger chunkSize

data FileChunk = FileChunk {chunkNo :: Integer, chunkBytes :: ByteString} | FileChunkCancel

instance Encoding FileChunk where
  smpEncode = \case
    FileChunk {chunkNo, chunkBytes} -> smpEncode ('F', fromIntegral chunkNo :: Word32, Tail chunkBytes)
    FileChunkCancel -> smpEncode 'C'
  smpP =
    smpP >>= \case
      'F' -> do
        chunkNo <- fromIntegral <$> smpP @Word32
        Tail chunkBytes <- smpP
        pure FileChunk {chunkNo, chunkBytes}
      'C' -> pure FileChunkCancel
      _ -> fail "bad FileChunk"

parseFileChunk :: ChatMonad m => ByteString -> m FileChunk
parseFileChunk msg =
  liftEither . first (ChatError . CEFileRcvChunk) $ parseAll smpP msg

appendFileChunk :: ChatMonad m => RcvFileTransfer -> Integer -> ByteString -> m ()
appendFileChunk ft@RcvFileTransfer {fileId, fileStatus} chunkNo chunk =
  case fileStatus of
    RFSConnected RcvFileInfo {filePath} -> append_ filePath
    -- sometimes update of file transfer status to FSConnected
    -- doesn't complete in time before MSG with first file chunk
    RFSAccepted RcvFileInfo {filePath} -> append_ filePath
    RFSCancelled _ -> pure ()
    _ -> throwChatError $ CEFileInternal "receiving file transfer not in progress"
  where
    append_ filePath = do
      fsFilePath <- toFSFilePath filePath
      h <- getFileHandle fileId fsFilePath rcvFiles AppendMode
      E.try (liftIO $ B.hPut h chunk >> hFlush h) >>= \case
        Left (e :: E.SomeException) -> throwChatError . CEFileWrite fsFilePath $ show e
        Right () -> withStore' $ \db -> updatedRcvFileChunkStored db ft chunkNo

getFileHandle :: ChatMonad m => Int64 -> FilePath -> (ChatController -> TVar (Map Int64 Handle)) -> IOMode -> m Handle
getFileHandle fileId filePath files ioMode = do
  fs <- asks files
  h_ <- M.lookup fileId <$> readTVarIO fs
  maybe (newHandle fs) pure h_
  where
    newHandle fs = do
      -- TODO handle errors
      h <- liftIO (openFile filePath ioMode)
      atomically . modifyTVar fs $ M.insert fileId h
      pure h

isFileActive :: ChatMonad m => Int64 -> (ChatController -> TVar (Map Int64 Handle)) -> m Bool
isFileActive fileId files = do
  fs <- asks files
  isJust . M.lookup fileId <$> readTVarIO fs

cancelRcvFileTransfer :: ChatMonad m => User -> RcvFileTransfer -> m ()
cancelRcvFileTransfer user ft@RcvFileTransfer {fileId, fileStatus} = do
  closeFileHandle fileId rcvFiles
  withStore' $ \db -> do
    updateFileCancelled db user fileId CIFSRcvCancelled
    updateRcvFileStatus db ft FSCancelled
    deleteRcvFileChunks db ft
  case fileStatus of
    RFSAccepted RcvFileInfo {agentConnId = AgentConnId acId} ->
      withAgent (`deleteConnection` acId)
    RFSConnected RcvFileInfo {agentConnId = AgentConnId acId} ->
      withAgent (`deleteConnection` acId)
    _ -> pure ()

cancelSndFile :: ChatMonad m => User -> FileTransferMeta -> [SndFileTransfer] -> m ()
cancelSndFile user FileTransferMeta {fileId} fts = do
  withStore' $ \db -> updateFileCancelled db user fileId CIFSSndCancelled
  forM_ fts $ \ft' -> cancelSndFileTransfer ft'

cancelSndFileTransfer :: ChatMonad m => SndFileTransfer -> m ()
cancelSndFileTransfer ft@SndFileTransfer {agentConnId = AgentConnId acId, fileStatus} =
  unless (fileStatus == FSCancelled || fileStatus == FSComplete) $ do
    withStore' $ \db -> do
      updateSndFileStatus db ft FSCancelled
      deleteSndFileChunks db ft
    withAgent $ \a -> do
      void (sendMessage a acId SMP.noMsgFlags $ smpEncode FileChunkCancel) `catchError` \_ -> pure ()
      deleteConnection a acId

closeFileHandle :: ChatMonad m => Int64 -> (ChatController -> TVar (Map Int64 Handle)) -> m ()
closeFileHandle fileId files = do
  fs <- asks files
  h_ <- atomically . stateTVar fs $ \m -> (M.lookup fileId m, M.delete fileId m)
  mapM_ hClose h_ `E.catch` \(_ :: E.SomeException) -> pure ()

throwChatError :: ChatMonad m => ChatErrorType -> m a
throwChatError = throwError . ChatError

deleteMemberConnection :: ChatMonad m => GroupMember -> m ()
deleteMemberConnection m@GroupMember {activeConn} = do
  -- User {userId} <- asks currentUser
  withAgent (forM_ (memberConnId m) . deleteConnection) `catchError` const (pure ())
  -- withStore $ \db -> deleteGroupMemberConnection db userId m
  forM_ activeConn $ \conn -> withStore' $ \db -> updateConnectionStatus db conn ConnDeleted

sendDirectContactMessage :: ChatMonad m => Contact -> ChatMsgEvent -> m SndMessage
sendDirectContactMessage ct@Contact {activeConn = conn@Connection {connId, connStatus}} chatMsgEvent = do
  if connStatus == ConnReady || connStatus == ConnSndReady
    then sendDirectMessage conn chatMsgEvent (ConnectionId connId)
    else throwChatError $ CEContactNotReady ct

sendDirectMessage :: ChatMonad m => Connection -> ChatMsgEvent -> ConnOrGroupId -> m SndMessage
sendDirectMessage conn chatMsgEvent connOrGroupId = do
  msg@SndMessage {msgId, msgBody} <- createSndMessage chatMsgEvent connOrGroupId
  deliverMessage conn (toCMEventTag chatMsgEvent) msgBody msgId
  pure msg

createSndMessage :: ChatMonad m => ChatMsgEvent -> ConnOrGroupId -> m SndMessage
createSndMessage chatMsgEvent connOrGroupId = do
  gVar <- asks idsDrg
  withStore $ \db -> createNewSndMessage db gVar connOrGroupId $ \sharedMsgId ->
    let msgBody = strEncode ChatMessage {msgId = Just sharedMsgId, chatMsgEvent}
     in NewMessage {chatMsgEvent, msgBody}

directMessage :: ChatMsgEvent -> ByteString
directMessage chatMsgEvent = strEncode ChatMessage {msgId = Nothing, chatMsgEvent}

deliverMessage :: ChatMonad m => Connection -> CMEventTag -> MsgBody -> MessageId -> m ()
deliverMessage conn@Connection {connId} cmEventTag msgBody msgId = do
  let msgFlags = MsgFlags {notification = hasNotification cmEventTag}
  agentMsgId <- withAgent $ \a -> sendMessage a (aConnId conn) msgFlags msgBody
  let sndMsgDelivery = SndMsgDelivery {connId, agentMsgId}
  withStore' $ \db -> createSndMsgDelivery db sndMsgDelivery msgId

sendGroupMessage :: ChatMonad m => GroupInfo -> [GroupMember] -> ChatMsgEvent -> m SndMessage
sendGroupMessage GroupInfo {groupId} members chatMsgEvent =
  sendGroupMessage' members chatMsgEvent groupId Nothing $ pure ()

sendXGrpMemInv :: ChatMonad m => GroupInfo -> GroupMember -> ChatMsgEvent -> Int64 -> m SndMessage
sendXGrpMemInv GroupInfo {groupId} reMember chatMsgEvent introId =
  sendGroupMessage' [reMember] chatMsgEvent groupId (Just introId) $
    withStore' $ \db -> updateIntroStatus db introId GMIntroInvForwarded

sendGroupMessage' :: ChatMonad m => [GroupMember] -> ChatMsgEvent -> Int64 -> Maybe Int64 -> m () -> m SndMessage
sendGroupMessage' members chatMsgEvent groupId introId_ postDeliver = do
  msg@SndMessage {msgId, msgBody} <- createSndMessage chatMsgEvent (GroupId groupId)
  -- TODO collect failed deliveries into a single error
  forM_ (filter memberCurrent members) $ \m@GroupMember {groupMemberId} ->
    case memberConn m of
      Nothing -> withStore' $ \db -> createPendingGroupMessage db groupMemberId msgId introId_
      Just conn@Connection {connStatus}
        | connStatus == ConnSndReady || connStatus == ConnReady -> do
          let tag = toCMEventTag chatMsgEvent
          (deliverMessage conn tag msgBody msgId >> postDeliver) `catchError` const (pure ())
        | connStatus == ConnDeleted -> pure ()
        | otherwise -> withStore' $ \db -> createPendingGroupMessage db groupMemberId msgId introId_
  pure msg

sendPendingGroupMessages :: ChatMonad m => GroupMember -> Connection -> m ()
sendPendingGroupMessages GroupMember {groupMemberId, localDisplayName} conn = do
  pendingMessages <- withStore' $ \db -> getPendingGroupMessages db groupMemberId
  -- TODO ensure order - pending messages interleave with user input messages
  forM_ pendingMessages $ \PendingGroupMessage {msgId, cmEventTag, msgBody, introId_} -> do
    deliverMessage conn cmEventTag msgBody msgId
    withStore' $ \db -> deletePendingGroupMessage db groupMemberId msgId
    when (cmEventTag == XGrpMemFwd_) $ case introId_ of
      Nothing -> throwChatError $ CEGroupMemberIntroNotFound localDisplayName
      Just introId -> withStore' $ \db -> updateIntroStatus db introId GMIntroInvForwarded

saveRcvMSG :: ChatMonad m => Connection -> ConnOrGroupId -> MsgMeta -> MsgBody -> m RcvMessage
saveRcvMSG Connection {connId} connOrGroupId agentMsgMeta msgBody = do
  ChatMessage {msgId = sharedMsgId_, chatMsgEvent} <- liftEither $ parseChatMessage msgBody
  let agentMsgId = fst $ recipient agentMsgMeta
      newMsg = NewMessage {chatMsgEvent, msgBody}
      rcvMsgDelivery = RcvMsgDelivery {connId, agentMsgId, agentMsgMeta}
  withStore' $ \db -> createNewMessageAndRcvMsgDelivery db connOrGroupId newMsg sharedMsgId_ rcvMsgDelivery

saveSndChatItem :: ChatMonad m => User -> ChatDirection c 'MDSnd -> SndMessage -> CIContent 'MDSnd -> Maybe (CIFile 'MDSnd) -> Maybe (CIQuote c) -> m (ChatItem c 'MDSnd)
saveSndChatItem user cd msg@SndMessage {sharedMsgId} content ciFile quotedItem = do
  createdAt <- liftIO getCurrentTime
  ciId <- withStore' $ \db -> createNewSndChatItem db user cd msg content quotedItem createdAt
  forM_ ciFile $ \CIFile {fileId} -> withStore' $ \db -> updateFileTransferChatItemId db fileId ciId
  liftIO $ mkChatItem cd ciId content ciFile quotedItem (Just sharedMsgId) createdAt createdAt

saveRcvChatItem :: ChatMonad m => User -> ChatDirection c 'MDRcv -> RcvMessage -> MsgMeta -> CIContent 'MDRcv -> Maybe (CIFile 'MDRcv) -> m (ChatItem c 'MDRcv)
saveRcvChatItem user cd msg@RcvMessage {sharedMsgId_} = saveRcvChatItem' user cd msg sharedMsgId_

saveRcvChatItem' :: ChatMonad m => User -> ChatDirection c 'MDRcv -> RcvMessage -> Maybe SharedMsgId -> MsgMeta -> CIContent 'MDRcv -> Maybe (CIFile 'MDRcv) -> m (ChatItem c 'MDRcv)
saveRcvChatItem' user cd msg sharedMsgId_ MsgMeta {broker = (_, brokerTs)} content ciFile = do
  createdAt <- liftIO getCurrentTime
  (ciId, quotedItem) <- withStore' $ \db -> createNewRcvChatItem db user cd msg sharedMsgId_ content brokerTs createdAt
  forM_ ciFile $ \CIFile {fileId} -> withStore' $ \db -> updateFileTransferChatItemId db fileId ciId
  liftIO $ mkChatItem cd ciId content ciFile quotedItem sharedMsgId_ brokerTs createdAt

mkChatItem :: MsgDirectionI d => ChatDirection c d -> ChatItemId -> CIContent d -> Maybe (CIFile d) -> Maybe (CIQuote c) -> Maybe SharedMsgId -> ChatItemTs -> UTCTime -> IO (ChatItem c d)
mkChatItem cd ciId content file quotedItem sharedMsgId itemTs currentTs = do
  tz <- getCurrentTimeZone
  let itemText = ciContentToText content
      meta = mkCIMeta ciId content itemText ciStatusNew sharedMsgId False False tz currentTs itemTs currentTs currentTs
  pure ChatItem {chatDir = toCIDirection cd, meta, content, formattedText = parseMaybeMarkdownList itemText, quotedItem, file}

allowAgentConnection :: ChatMonad m => Connection -> ConfirmationId -> ChatMsgEvent -> m ()
allowAgentConnection conn confId msg = do
  withAgent $ \a -> allowConnection a (aConnId conn) confId $ directMessage msg
  withStore' $ \db -> updateConnectionStatus db conn ConnAccepted

getCreateActiveUser :: SQLiteStore -> IO User
getCreateActiveUser st = do
  user <-
    withTransaction st getUsers >>= \case
      [] -> newUser
      users -> maybe (selectUser users) pure (find activeUser users)
  putStrLn $ "Current user: " <> userStr user
  pure user
  where
    newUser :: IO User
    newUser = do
      putStrLn
        "No user profiles found, it will be created now.\n\
        \Please choose your display name and your full name.\n\
        \They will be sent to your contacts when you connect.\n\
        \They are only stored on your device and you can change them later."
      loop
      where
        loop = do
          displayName <- getContactName
          fullName <- T.pack <$> getWithPrompt "full name (optional)"
          withTransaction st (\db -> runExceptT $ createUser db Profile {displayName, fullName, image = Nothing} True) >>= \case
            Left SEDuplicateName -> do
              putStrLn "chosen display name is already used by another profile on this device, choose another one"
              loop
            Left e -> putStrLn ("database error " <> show e) >> exitFailure
            Right user -> pure user
    selectUser :: [User] -> IO User
    selectUser [user] = do
      withTransaction st (`setActiveUser` userId user)
      pure user
    selectUser users = do
      putStrLn "Select user profile:"
      forM_ (zip [1 ..] users) $ \(n :: Int, user) -> putStrLn $ show n <> " - " <> userStr user
      loop
      where
        loop = do
          nStr <- getWithPrompt $ "user profile number (1 .. " <> show (length users) <> ")"
          case readMaybe nStr :: Maybe Int of
            Nothing -> putStrLn "invalid user number" >> loop
            Just n
              | n <= 0 || n > length users -> putStrLn "invalid user number" >> loop
              | otherwise -> do
                let user = users !! (n - 1)
                withTransaction st (`setActiveUser` userId user)
                pure user
    userStr :: User -> String
    userStr User {localDisplayName, profile = Profile {fullName}} =
      T.unpack $ localDisplayName <> if T.null fullName || localDisplayName == fullName then "" else " (" <> fullName <> ")"
    getContactName :: IO ContactName
    getContactName = do
      displayName <- getWithPrompt "display name (no spaces)"
      if null displayName || isJust (find (== ' ') displayName)
        then putStrLn "display name has space(s), choose another one" >> getContactName
        else pure $ T.pack displayName
    getWithPrompt :: String -> IO String
    getWithPrompt s = putStr (s <> ": ") >> hFlush stdout >> getLine

showMsgToast :: (MonadUnliftIO m, MonadReader ChatController m) => Text -> MsgContent -> Maybe MarkdownList -> m ()
showMsgToast from mc md_ = showToast from $ maybe (msgContentText mc) (mconcat . map hideSecret) md_
  where
    hideSecret :: FormattedText -> Text
    hideSecret FormattedText {format = Just Secret} = "..."
    hideSecret FormattedText {text} = text

showToast :: (MonadUnliftIO m, MonadReader ChatController m) => Text -> Text -> m ()
showToast title text = atomically . (`writeTBQueue` Notification {title, text}) =<< asks notifyQ

notificationSubscriber :: (MonadUnliftIO m, MonadReader ChatController m) => m ()
notificationSubscriber = do
  ChatController {notifyQ, sendNotification} <- ask
  forever $ atomically (readTBQueue notifyQ) >>= liftIO . sendNotification

withUser' :: ChatMonad m => (User -> m a) -> m a
withUser' action =
  asks currentUser
    >>= readTVarIO
    >>= maybe (throwChatError CENoActiveUser) action

withUser :: ChatMonad m => (User -> m a) -> m a
withUser action = withUser' $ \user ->
  ifM chatStarted (action user) (throwChatError CEChatNotStarted)
  where
    chatStarted = fmap isJust . readTVarIO =<< asks agentAsync

withAgent :: ChatMonad m => (AgentClient -> ExceptT AgentErrorType m a) -> m a
withAgent action =
  asks smpAgent
    >>= runExceptT . action
    >>= liftEither . first ChatErrorAgent

withStore' :: ChatMonad m => (DB.Connection -> IO a) -> m a
withStore' action = withStore $ liftIO . action

withStore ::
  ChatMonad m =>
  (DB.Connection -> ExceptT StoreError IO a) ->
  m a
withStore action = do
  st <- asks chatStore
  liftEitherError ChatErrorStore $
    withTransaction st (runExceptT . action) `E.catch` handleInternal
  where
    handleInternal :: E.SomeException -> IO (Either StoreError a)
    handleInternal = pure . Left . SEInternalError . show

chatCommandP :: Parser ChatCommand
chatCommandP =
  ("/user " <|> "/u ") *> (CreateActiveUser <$> userProfile)
    <|> ("/user" <|> "/u") $> ShowActiveUser
    <|> "/_start subscribe=" *> (StartChat <$> ("on" $> True <|> "off" $> False))
    <|> "/_start" $> StartChat True
    <|> "/_stop" $> APIStopChat
    <|> "/_app activate" $> APIActivateChat
    <|> "/_app suspend " *> (APISuspendChat <$> A.decimal)
    <|> "/_resubscribe all" $> ResubscribeAllConnections
    <|> "/_files_folder " *> (SetFilesFolder <$> filePath)
    <|> "/_db export " *> (APIExportArchive <$> jsonP)
    <|> "/_db import " *> (APIImportArchive <$> jsonP)
    <|> "/_db delete" $> APIDeleteStorage
    <|> "/_get chats" *> (APIGetChats <$> (" pcc=on" $> True <|> " pcc=off" $> False <|> pure False))
    <|> "/_get chat " *> (APIGetChat <$> chatRefP <* A.space <*> chatPaginationP)
    <|> "/_get items count=" *> (APIGetChatItems <$> A.decimal)
    <|> "/_send " *> (APISendMessage <$> chatRefP <*> (" json " *> jsonP <|> " text " *> (ComposedMessage Nothing Nothing <$> mcTextP)))
    <|> "/_update item " *> (APIUpdateChatItem <$> chatRefP <* A.space <*> A.decimal <* A.space <*> msgContentP)
    <|> "/_delete item " *> (APIDeleteChatItem <$> chatRefP <* A.space <*> A.decimal <* A.space <*> ciDeleteMode)
    <|> "/_read chat " *> (APIChatRead <$> chatRefP <*> optional (A.space *> ((,) <$> ("from=" *> A.decimal) <* A.space <*> ("to=" *> A.decimal))))
    <|> "/_delete " *> (APIDeleteChat <$> chatRefP)
    <|> "/_clear chat " *> (APIClearChat <$> chatRefP)
    <|> "/_accept " *> (APIAcceptContact <$> A.decimal)
    <|> "/_reject " *> (APIRejectContact <$> A.decimal)
    <|> "/_call invite @" *> (APISendCallInvitation <$> A.decimal <* A.space <*> jsonP)
    <|> ("/call @" <|> "/call ") *> (SendCallInvitation <$> displayName <*> pure defaultCallType)
    <|> "/_call reject @" *> (APIRejectCall <$> A.decimal)
    <|> "/_call offer @" *> (APISendCallOffer <$> A.decimal <* A.space <*> jsonP)
    <|> "/_call answer @" *> (APISendCallAnswer <$> A.decimal <* A.space <*> jsonP)
    <|> "/_call extra @" *> (APISendCallExtraInfo <$> A.decimal <* A.space <*> jsonP)
    <|> "/_call end @" *> (APIEndCall <$> A.decimal)
    <|> "/_call status @" *> (APICallStatus <$> A.decimal <* A.space <*> strP)
    <|> "/_profile " *> (APIUpdateProfile <$> jsonP)
    <|> "/_parse " *> (APIParseMarkdown . safeDecodeUtf8 <$> A.takeByteString)
    <|> "/_ntf get" $> APIGetNtfToken
    <|> "/_ntf register " *> (APIRegisterToken <$> strP_ <*> strP)
    <|> "/_ntf verify " *> (APIVerifyToken <$> strP <* A.space <*> strP <* A.space <*> strP)
    <|> "/_ntf delete " *> (APIDeleteToken <$> strP)
    <|> "/_ntf message " *> (APIGetNtfMessage <$> strP <* A.space <*> strP)
    <|> "/smp_servers default" $> SetUserSMPServers []
    <|> "/smp_servers " *> (SetUserSMPServers <$> smpServersP)
    <|> "/smp_servers" $> GetUserSMPServers
    <|> ("/help files" <|> "/help file" <|> "/hf") $> ChatHelp HSFiles
    <|> ("/help groups" <|> "/help group" <|> "/hg") $> ChatHelp HSGroups
    <|> ("/help address" <|> "/ha") $> ChatHelp HSMyAddress
    <|> ("/help messages" <|> "/hm") $> ChatHelp HSMessages
    <|> ("/help" <|> "/h") $> ChatHelp HSMain
    <|> ("/group #" <|> "/group " <|> "/g #" <|> "/g ") *> (NewGroup <$> groupProfile)
    <|> ("/add #" <|> "/add " <|> "/a #" <|> "/a ") *> (AddMember <$> displayName <* A.space <*> displayName <*> memberRole)
    <|> ("/join #" <|> "/join " <|> "/j #" <|> "/j ") *> (JoinGroup <$> displayName)
    <|> ("/remove #" <|> "/remove " <|> "/rm #" <|> "/rm ") *> (RemoveMember <$> displayName <* A.space <*> displayName)
    <|> ("/leave #" <|> "/leave " <|> "/l #" <|> "/l ") *> (LeaveGroup <$> displayName)
    <|> ("/delete #" <|> "/d #") *> (DeleteGroup <$> displayName)
    <|> ("/delete @" <|> "/delete " <|> "/d @" <|> "/d ") *> (DeleteContact <$> displayName)
    <|> "/clear #" *> (ClearGroup <$> displayName)
    <|> ("/clear @" <|> "/clear ") *> (ClearContact <$> displayName)
    <|> ("/members #" <|> "/members " <|> "/ms #" <|> "/ms ") *> (ListMembers <$> displayName)
    <|> ("/groups" <|> "/gs") $> ListGroups
    <|> (">#" <|> "> #") *> (SendGroupMessageQuote <$> displayName <* A.space <*> pure Nothing <*> quotedMsg <*> A.takeByteString)
    <|> (">#" <|> "> #") *> (SendGroupMessageQuote <$> displayName <* A.space <* optional (A.char '@') <*> (Just <$> displayName) <* A.space <*> quotedMsg <*> A.takeByteString)
    <|> ("/contacts" <|> "/cs") $> ListContacts
    <|> ("/connect " <|> "/c ") *> (Connect <$> ((Just <$> strP) <|> A.takeByteString $> Nothing))
    <|> ("/connect" <|> "/c") $> AddContact
    <|> (SendMessage <$> chatNameP <* A.space <*> A.takeByteString)
    <|> (">@" <|> "> @") *> sendMsgQuote (AMsgDirection SMDRcv)
    <|> (">>@" <|> ">> @") *> sendMsgQuote (AMsgDirection SMDSnd)
    <|> ("\\ " <|> "\\") *> (DeleteMessage <$> chatNameP <* A.space <*> A.takeByteString)
    <|> ("! " <|> "!") *> (EditMessage <$> chatNameP <* A.space <*> (quotedMsg <|> pure "") <*> A.takeByteString)
    <|> "/feed " *> (SendMessageBroadcast <$> A.takeByteString)
    <|> ("/tail" <|> "/t") *> (LastMessages <$> optional (A.space *> chatNameP) <*> msgCountP)
    <|> ("/file " <|> "/f ") *> (SendFile <$> chatNameP' <* A.space <*> filePath)
    <|> ("/image " <|> "/img ") *> (SendImage <$> chatNameP' <* A.space <*> filePath)
    <|> ("/fforward " <|> "/ff ") *> (ForwardFile <$> chatNameP' <* A.space <*> A.decimal)
    <|> ("/image_forward " <|> "/imgf ") *> (ForwardImage <$> chatNameP' <* A.space <*> A.decimal)
    <|> ("/freceive " <|> "/fr ") *> (ReceiveFile <$> A.decimal <*> optional (A.space *> filePath))
    <|> ("/fcancel " <|> "/fc ") *> (CancelFile <$> A.decimal)
    <|> ("/fstatus " <|> "/fs ") *> (FileStatus <$> A.decimal)
    <|> "/simplex" $> ConnectSimplex
    <|> ("/address" <|> "/ad") $> CreateMyAddress
    <|> ("/delete_address" <|> "/da") $> DeleteMyAddress
    <|> ("/show_address" <|> "/sa") $> ShowMyAddress
    <|> "/auto_accept " *> (AddressAutoAccept <$> onOffP <*> optional (A.space *> msgContentP))
    <|> ("/accept @" <|> "/accept " <|> "/ac @" <|> "/ac ") *> (AcceptContact <$> displayName)
    <|> ("/reject @" <|> "/reject " <|> "/rc @" <|> "/rc ") *> (RejectContact <$> displayName)
    <|> ("/markdown" <|> "/m") $> ChatHelp HSMarkdown
    <|> ("/welcome" <|> "/w") $> Welcome
    <|> "/profile_image " *> (UpdateProfileImage . Just . ImageData <$> imageP)
    <|> "/profile_image" $> UpdateProfileImage Nothing
    <|> ("/profile " <|> "/p ") *> (uncurry UpdateProfile <$> userNames)
    <|> ("/profile" <|> "/p") $> ShowProfile
    <|> ("/quit" <|> "/q" <|> "/exit") $> QuitChat
    <|> ("/version" <|> "/v") $> ShowVersion
  where
    imagePrefix = (<>) <$> "data:" <*> ("image/png;base64," <|> "image/jpg;base64,")
    imageP = safeDecodeUtf8 <$> ((<>) <$> imagePrefix <*> (B64.encode <$> base64P))
    chatTypeP = A.char '@' $> CTDirect <|> A.char '#' $> CTGroup <|> A.char ':' $> CTContactConnection
    chatPaginationP =
      (CPLast <$ "count=" <*> A.decimal)
        <|> (CPAfter <$ "after=" <*> A.decimal <* A.space <* "count=" <*> A.decimal)
        <|> (CPBefore <$ "before=" <*> A.decimal <* A.space <* "count=" <*> A.decimal)
    mcTextP = MCText . safeDecodeUtf8 <$> A.takeByteString
    msgContentP = "text " *> mcTextP <|> "json " *> jsonP
    ciDeleteMode = "broadcast" $> CIDMBroadcast <|> "internal" $> CIDMInternal
    displayName = safeDecodeUtf8 <$> (B.cons <$> A.satisfy refChar <*> A.takeTill (== ' '))
    sendMsgQuote msgDir = SendMessageQuote <$> displayName <* A.space <*> pure msgDir <*> quotedMsg <*> A.takeByteString
    quotedMsg = A.char '(' *> A.takeTill (== ')') <* A.char ')' <* optional A.space
    refChar c = c > ' ' && c /= '#' && c /= '@'
    onOffP = ("on" $> True) <|> ("off" $> False)
    userNames = do
      cName <- displayName
      fullName <- fullNameP cName
      pure (cName, fullName)
    userProfile = do
      (cName, fullName) <- userNames
      pure Profile {displayName = cName, fullName, image = Nothing}
    jsonP :: J.FromJSON a => Parser a
    jsonP = J.eitherDecodeStrict' <$?> A.takeByteString
    groupProfile = do
      gName <- displayName
      fullName <- fullNameP gName
      pure GroupProfile {displayName = gName, fullName, image = Nothing}
    fullNameP name = do
      n <- (A.space *> A.takeByteString) <|> pure ""
      pure $ if B.null n then name else safeDecodeUtf8 n
    filePath = T.unpack . safeDecodeUtf8 <$> A.takeByteString
    memberRole =
      (" owner" $> GROwner)
        <|> (" admin" $> GRAdmin)
        <|> (" member" $> GRMember)
        <|> pure GRAdmin
    chatNameP = ChatName <$> chatTypeP <*> displayName
    chatNameP' = ChatName <$> (chatTypeP <|> pure CTDirect) <*> displayName
    chatRefP = ChatRef <$> chatTypeP <*> A.decimal
    msgCountP = A.space *> A.decimal <|> pure 10

adminContactReq :: ConnReqContact
adminContactReq =
  either error id $ strDecode "https://simplex.chat/contact#/?v=1&smp=smp%3A%2F%2FPQUV2eL0t7OStZOoAsPEV2QYWt4-xilbakvGUGOItUo%3D%40smp6.simplex.im%2FK1rslx-m5bpXVIdMZg9NLUZ_8JBm8xTt%23MCowBQYDK2VuAyEALDeVe-sG8mRY22LsXlPgiwTNs9dbiLrNuA7f3ZMAJ2w%3D"

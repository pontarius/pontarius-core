{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}

module Gpg where

import           Control.Applicative
import qualified Control.Exception as Ex
import           Control.Monad
import           Control.Monad.Trans.Maybe
import           Control.Monad.Reader
import           DBus
import qualified DBus.Types as DBus
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Maybe
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text.Encoding as Text
import qualified GpgMe as Gpg
import qualified Network.Xmpp as Xmpp
import           System.Log.Logger

--import           Network.Xmpp.E2E


import           Basic
import           Persist
import           Types


mkKeyRSA :: String -> String
mkKeyRSA name = unlines $
 [ "<GnupgKeyParms format=\"internal\">"
 , "Key-Type: RSA"
 , "Key-Length: 4096"
 , "Key-Usage: sign, auth"
 , "Expire-Date: 0"
 , "Name-Real: " ++ name
 , "</GnupgKeyParms>"
 ]

pontariusKeyName :: String
pontariusKeyName = "Pontarius-Service"

newGpgKey :: IO BS.ByteString
newGpgKey = do
    ctx <- Gpg.ctxNew Nothing
    Just kid <- Gpg.genKeyFingerprint <$>
                   Gpg.genKey ctx (mkKeyRSA $ pontariusKeyName)
    return kid

fromKeyID :: KeyID -> BS.ByteString
fromKeyID = Text.encodeUtf8

toKeyID :: BS.ByteString -> KeyID
toKeyID = Text.decodeUtf8

revokeIdentity :: MonadIO m => KeyID -> MethodHandlerT m ()
revokeIdentity keyID = do
    let text = "" :: Text
        reason = Gpg.NoReason
    ctx <- liftIO $ Gpg.ctxNew Nothing
    keys <- liftIO $ Gpg.findKeyBy ctx True Gpg.keyFingerprint
              (Just $ fromKeyID keyID)
    case keys of
        [key] -> liftIO $ Gpg.revoke ctx key reason text >> return ()
        [] -> DBus.methodError $
                   MsgError{ errorName = "org.pontarius.Error.Revoke"
                           , errorText = Just "Key not found"
                           , errorBody = []
                           }
        _ -> DBus.methodError $
                   MsgError{ errorName = "org.pontarius.Error.Revoke"
                           , errorText = Just "Key not unique"
                           , errorBody = []
                           }
    return ()

setSigningGpgKey :: PSState -> KeyID -> IO Bool
setSigningGpgKey st keyID = do
    let keyFpr = fromKeyID keyID
    ctx <- Gpg.ctxNew Nothing
    keys <- Gpg.getKeys ctx True
    matches <- filterM (liftM (== Just keyFpr) . Gpg.keyFingerprint) keys
    haveKey <- case matches of
        [] -> return False
        (_:_) -> return True
    runPSM st . when haveKey $ setSigningKey "gpg" (toKeyID keyFpr)
    return haveKey


getSigningPgpKey :: PSState -> DBus.MethodHandlerT IO KeyID
getSigningPgpKey st = do
    pIdent <- (runPSM st $ getSigningKey) >>= \case
        Just pi -> return pi
        Nothing -> do
            DBus.methodError $
                   MsgError{ errorName = "org.pontarius.Error.Sign"
                           , errorText = Just "No signing key found"
                           , errorBody = []
                           }
    case privIdentKeyBackend pIdent of
        "gpg" -> return $ privIdentKeyID pIdent
        backend -> DBus.methodError $
             MsgError { errorName = "org.pontarius.Error.Sign"
                      , errorText = Just $ "Unknown key backend " <> backend
                      , errorBody = []
                      }

identityProp :: PSState -> Property ('DBusSimpleType 'TypeString)
identityProp st =
    mkProperty pontariusObjectPath pontariusInterface "Identity"
    (Just $ getSigningPgpKey st) Nothing
    PECSTrue

--setSigningKey st keyFpr

getIdentities :: IO [KeyID]
getIdentities = do
    ctx <- Gpg.ctxNew Nothing
    keys <- Gpg.getKeys ctx True
    map toKeyID . catMaybes <$> mapM Gpg.keyFingerprint keys

-- |  Get all available private keys
getIdentitiesMethod :: Method
getIdentitiesMethod  =
    DBus.Method
    (DBus.repMethod $ (getIdentities :: IO [KeyID] ))
    "getIdentities"
    Result
    ("identities" -- ^ List of keyIDs
     :> ResultDone)

importKey :: MonadIO m => t -> ByteString -> PSM m [ByteString]
importKey _peer key = do
    ctx <- liftIO $ Gpg.ctxNew Nothing
    importResults <- liftIO $ Gpg.importKeys ctx key
    liftM catMaybes $ forM importResults $ \res ->
        case Gpg.isResult res of
            Nothing -> do
                let fPrint = Gpg.isFprint res
--                addPeerKey st peer (PubKey "gpg" fPrint)
                return $ Just fPrint
            Just err -> do
                liftIO . errorM "Pontarius.Xmpp" $ "error while importing key" ++ show err
                return Nothing

exportSigningGpgKey :: PSState -> IO (Maybe ByteString)
exportSigningGpgKey st = do
    mbKey <- runPSM st getSigningKey
    case mbKey of
        Just key | privIdentKeyBackend key == "gpg" -> do
            let kid = fromKeyID $ privIdentKeyID key
            ctx <- Gpg.ctxNew Nothing
            keys <- Gpg.getKeys ctx True
            candidates <- filterM (\k -> (== Just kid) <$> Gpg.keyFingerprint k) keys
            case candidates of
                (k:_) -> Just <$> Gpg.exportKeys ctx [k]
                _ -> return Nothing
        _ -> return Nothing

signGPG :: MonadIO m =>
           BS.ByteString
        -> BS.ByteString
        -> m BS.ByteString
signGPG kid bs = liftIO $ do
    ctx <- Gpg.ctxNew Nothing
    keys <- Gpg.getKeys ctx True
    matches <- filterM (liftM (== Just kid) . Gpg.keyFingerprint) keys
    case matches of
        [] -> error "key does not exist" -- return Nothing
        (p:_) -> do
            sig <- Gpg.sign ctx bs p Gpg.SigModeDetach
            debug$ "Signing " ++ show bs ++ " yielded " ++ show sig
            return sig

verifyGPG :: PSState
          -> Xmpp.Jid
          -> ByteString
          -> ByteString
          -> ByteString
          -> IO Bool
verifyGPG st peer kid sig txt = liftM (fromMaybe False) . runMaybeT $ do
    -- Firstly check that we have the pubkey on file for that key
    mbKey <- liftIO  . runPSM st $ getPeerIdent peer
    case mbKey of
        Nothing -> mzero
        Just kid' -> guard $ kid == (fromKeyID kid')
    liftIO $ do
        ctx <- Gpg.ctxNew Nothing
        debugM "Pontarius.Xmpp" $
            "Verifying signature "  ++ show sig ++ " for " ++ show txt
        res <- Ex.try $ Gpg.verifyDetach ctx txt sig -- Gpg.Error
        case res of
            Left (e :: Gpg.Error) -> do
                errorM "Pontarius.Xmpp"
                    $ "Verifying signature threw exception" ++ show e
                return False
            Right res | all (goodStat . Gpg.status) res -> do
                infoM "Pontarius.Xmpp" "Signature seems good."
                debugM "Pontarius.Xmpp" $ "result: " ++ show res
                return True
                      | otherwise -> do
                warningM "Pontarius.Xmpp" $ "Signature problem: " ++ show res
                return False
  where
    goodStat Gpg.SigStatGood = True
    goodStat _ = False

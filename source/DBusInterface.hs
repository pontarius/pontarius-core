{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}


module DBusInterface
   (rootObject) where

import qualified Control.Exception as Ex
import           DBus as DBus
import           DBus.Types
import           Data.Proxy
import           Data.Singletons
import           Data.String
import           Data.Text (Text)
import           Data.Typeable (Typeable)
import qualified Network.Xmpp as Xmpp

import           Basic
import           Gpg
import           Persist
import           Types
import           Xmpp

data Stub = Stub deriving (Show, Typeable)

instance Ex.Exception Stub

class IsStub a where
    stub :: a

instance IsStub (IO a) where
    stub = Ex.throwIO Stub

instance IsStub (MethodHandlerT IO a) where
    stub = methodError $ MsgError "pontarius.service.Error.Stub" Nothing []

instance IsStub b => IsStub (a -> b) where
    stub = \_ -> stub

pontariusProperty :: SingI t => Text -> Property t
pontariusProperty name =
    Property { propertyName = name
             , propertyPath = pontariusObjectPath
             , propertyInterface = pontariusInterface
             , propertyGet = Just stub
             , propertySet = Just stub
             , propertyEmitsChangedSignal = PECSTrue
             }

----------------------------------------------------
-- Methods
----------------------------------------------------

instance IsString (ResultDescription ('Arg 'Null)) where
    fromString t = (fromString t :> ResultDone)



securityHistoryByJidMethod :: Method
securityHistoryByJidMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Xmpp.Jid -> IO ( [AkeEvent]
                                              , [ChallengeEvent]
                                              , [RevocationEvent]
                                              , [RevocationSignalEvent]
                                              )))
    "securityHistoryByJID" ("peer" :-> Result )
    ( "ake_events"
      :> "challenge_events"
      :> "revocation_events"
      :> "revocation_signal_events"
      :> ResultDone
    )


securityHistoryByKeyIdMethod :: Method
securityHistoryByKeyIdMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Xmpp.Jid -> IO ( [AkeEvent]
                                         , [ChallengeEvent]
                                         , [RevocationEvent]
                                         , [RevocationSignalEvent]
                                         )))
    "securityHistoryByKeyID" ("key_id" :-> Result)
    ("ake_events"
     :> "challenge_events"
     :> "revocation_events"
     :> "revocation_signal_events"
     :> ResultDone
    )

initializeMethod :: PSState -> Method
initializeMethod st =
    DBus.Method
    (DBus.repMethod $ initalize st)
    "initialize" Result
    ("result" :> ResultDone)

connectMethod :: PSState -> Method
connectMethod st =
    DBus.Method
    (DBus.repMethod $ runPSM st connect)
    "connect" Result
    (ResultDone)

disconnectMethod :: PSState -> Method
disconnectMethod st =
    DBus.Method
    (DBus.repMethod $ runPSM st disconnect)
    "disconnect" Result
    (ResultDone)

reconnectMethod :: PSState -> Method
reconnectMethod st =
    DBus.Method
    (DBus.repMethod $ runPSM st reconnect)
    "reconnect" Result
    (ResultDone)

importKeyMethod :: Method
importKeyMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Text -> IO KeyID ))
    "importKey" ("location" :-> Result) "key_id"

markKeyVerifiedMethod :: Method
markKeyVerifiedMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: KeyID -> IO () ))
    "markKeyVerified" ("key-id" :-> Result) ResultDone

revokeKeymethod :: Method
revokeKeymethod =
    DBus.Method
    (DBus.repMethod $ (stub ::  KeyID -> Text -> IO ()))
    "revokeKey" ("key_id" :-> "reason" :-> Result) ResultDone

initiateChallengeMethod :: Method
initiateChallengeMethod =
    DBus.Method
    (DBus.repMethod $ (stub ::  Xmpp.Jid -> Text -> Text -> IO Text))
    "initiateChallenge" ("peer" :-> "question" :-> "secret" :-> Result)
    "challenge_id"

respondChallengeMethod :: Method
respondChallengeMethod =
    DBus.Method
    (DBus.repMethod $ (stub ::  Text -> Text -> IO ()))
    "respondChallenge" ("challenge_id" :-> "secret" :-> Result)
    ResultDone

getTrustStatusMethod :: Method
getTrustStatusMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Text -> IO Bool))
    "getTrustStatus" ("entity" :-> Result) "is_trusted"

getEntityPubkeyMethod :: Method
getEntityPubkeyMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Xmpp.Jid -> IO Text))
    "getEntityPubkey" ("entity" :-> Result)
    "key_id"

addPeerMethod :: Method
addPeerMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Xmpp.Jid -> Text -> IO ()))
    "addPeer" ("jid" :-> "name" :-> Result)
    ResultDone

removePeerMethod :: Method
removePeerMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Xmpp.Jid -> IO ()))
    "removePeer" ("entity" :-> Result)
    ResultDone

registerAccountMethod :: Method
registerAccountMethod =
    DBus.Method
    (DBus.repMethod $ (stub :: Text -> Text -> Text -> IO ()))
    "registerAccount" ("server" :-> "username" :-> "password"
                        :-> Result)
    ResultDone

sArgument :: SingI t => Text -> Proxy (t :: DBusType) -> SignalArgument
sArgument name (Proxy :: Proxy (t :: DBusType)) =
    SignalArgument { signalArgumentName = name
                   , signalArgumentType = fromSing (sing :: Sing t)
                   }

receivedChallengeSignal :: SignalInterface
receivedChallengeSignal = SignalI { signalName = "receivedChallenge"
                                  , signalArguments =
                                      [ sArgument "peer"
                                          (Proxy :: Proxy (RepType Xmpp.Jid))
                                      , sArgument "challenge_id"
                                          (Proxy :: Proxy (RepType Text))
                                      , sArgument "question"
                                          (Proxy :: Proxy (RepType Text))
                                      ]

                                  , signalAnnotations = []
                                  }

challengeResultSignal :: SignalInterface
challengeResultSignal = SignalI { signalName = "challengeResult"
                                , signalArguments =
                                    [ sArgument "peer"
                                      (Proxy :: Proxy (RepType Xmpp.Jid))
                                    , sArgument "challenge_id"
                                      (Proxy :: Proxy (RepType Text))
                                    , sArgument "initiator"
                                      (Proxy :: Proxy (RepType Text))
                                    , sArgument "result"
                                      (Proxy :: Proxy (RepType Bool))
                                    ]
                                , signalAnnotations = []
                                }

challengeTimeoutSignal :: SignalInterface
challengeTimeoutSignal = SignalI { signalName = "challengeTimeout"
                                , signalArguments =
                                    [ sArgument "peer"
                                      (Proxy :: Proxy (RepType Xmpp.Jid))
                                    , sArgument "challenge_id"
                                      (Proxy :: Proxy (RepType Text))
                                    ]
                                , signalAnnotations = []
                                }

peerStatusChangeSignal :: SignalInterface
peerStatusChangeSignal = SignalI { signalName = "peerStatusChanged"
                                 , signalArguments =
                                    [ sArgument "peer"
                                      (Proxy :: Proxy (RepType Xmpp.Jid))
                                    ,  sArgument "status"
                                      (Proxy :: Proxy (RepType Text))
                                    ]
                                , signalAnnotations = []
                                }

peerTrustStatusChangeSignal :: SignalInterface
peerTrustStatusChangeSignal = SignalI { signalName = "peerTrustStatusChanged"
                                      , signalArguments =
                                          [ sArgument "peer"
                                            (Proxy :: Proxy (RepType Xmpp.Jid))
                                          ,  sArgument "trust_status"
                                             (Proxy :: Proxy (RepType Text))
                                          ]
                                      , signalAnnotations = []
                                      }


connectionStatusProperty :: Property (RepType Text)
connectionStatusProperty = pontariusProperty "ConnectionStatus"

availableEntitiesProperty :: Property (RepType [Ent])
availableEntitiesProperty = pontariusProperty "AvailableEntities"

unavailanbleEntitiesProperty :: Property (RepType [Ent])
unavailanbleEntitiesProperty = pontariusProperty "UnvailableEntities"

passwordProperty :: PSState -> Property (RepType Text)
passwordProperty st = mkProperty pontariusObjectPath
                                 pontariusInterface
                                 "Password"
                                 Nothing
                                 (Just $ \pw -> runPSM st (setPassword pw)
                                                >> return False)
                                 PECSFalse

usernameProperty :: PSState -> Property (RepType Text)
usernameProperty st = mkProperty pontariusObjectPath
                                 pontariusInterface
                                 "Username"
                                 (Just $ runPSM st getUsername)
                                 (Just $ \pw -> runPSM st (setUsername pw)
                                                >> return True)
                                 PECSTrue

hostnameProperty :: PSState -> Property (RepType Text)
hostnameProperty st = mkProperty pontariusObjectPath
                                 pontariusInterface
                                 "Hostname"
                                 (Just $ runPSM st getHostname)
                                 (Just $ \pw -> runPSM st (setHostname pw)
                                                >> return True)
                                 PECSTrue



----------------------------------------------------
-- Objects
----------------------------------------------------

xmppInterface :: PSState -> Interface
xmppInterface st = Interface
                [ importKeyMethod
                , createKeyMethod st
                , initializeMethod st
                , markKeyVerifiedMethod
                , securityHistoryByJidMethod
                , securityHistoryByKeyIdMethod
                , revokeKeymethod
                , initiateChallengeMethod
                , respondChallengeMethod
                , getTrustStatusMethod
                , getEntityPubkeyMethod
                , addPeerMethod
                , removePeerMethod
                , registerAccountMethod
                , connectMethod st
                , disconnectMethod st
                , reconnectMethod st
                ] []
                [ receivedChallengeSignal
                , challengeResultSignal
                , challengeTimeoutSignal
                , peerStatusChangeSignal
                , peerTrustStatusChangeSignal
                ]
                [ SomeProperty $ passwordProperty st
                , SomeProperty $ usernameProperty st
                , SomeProperty $ hostnameProperty st
                , SomeProperty availableEntitiesProperty
                , SomeProperty unavailanbleEntitiesProperty
                , SomeProperty $ signingKeyProp st
                , SomeProperty connectionStatusProperty
                ]


conObject :: PSState -> Object
conObject st = object pontariusInterface (xmppInterface st)

rootObject :: PSState -> Objects
rootObject st = root pontariusObjectPath (conObject st)

{-
 Copyright (c) 2012-2017 "JUSPAY Technologies"
 JUSPAY Technologies Pvt. Ltd. [https://www.juspay.in]
 This file is part of JUSPAY Platform.
 JUSPAY Platform is free software: you can redistribute it and/or modify
 it for only educational purposes under the terms of the GNU Affero General
 Public License (GNU AGPL) as published by the Free Software Foundation,
 either version 3 of the License, or (at your option) any later version.
 For Enterprise/Commerical licenses, contact <info@juspay.in>.
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  The end user will
 be liable for all damages without limitation, which is caused by the
 ABUSE of the LICENSED SOFTWARE and shall INDEMNIFY JUSPAY for such
 damages, claims, cost, including reasonable attorney fee claimed on Juspay.
 The end user has NO right to claim any indemnification based on its use
 of Licensed Software. See the GNU Affero General Public License for more details.
 You should have received a copy of the GNU Affero General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/agpl.html>.
-}

module Presto.Backend.Flow where

import Prelude

import Control.Monad.Eff (Eff)
import Control.Monad.Aff (Aff)
import Control.Monad.Eff.Exception (Error, error, message)
import Control.Monad.Except (runExcept) as E
import Control.Monad.Free (Free, liftF)
import Data.Either (Either(..), note, hush, isLeft)
import Data.Exists (Exists, mkExists)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Newtype (class Newtype)
import Data.Foreign (Foreign, toForeign)
import Data.Foreign.Class (class Encode, class Decode, encode, decode)
import Data.Foreign.Generic (encodeJSON)
import Data.Lazy (defer)
import Data.Options (Options)
import Data.Options (options) as Opt
import Data.Time.Duration (Milliseconds, Seconds)
import Presto.Backend.DBImpl (findOne, findAll, create, createWithOpts, query, update, update', delete, getModelByName) as DB
import Presto.Backend.Types (BackendAff)
import Presto.Backend.Types.API (ErrorResponse, APIResult)
import Presto.Backend.APIInteract (apiInteract)
import Presto.Backend.Language.Types.EitherEx (EitherEx(..), fromCustomEitherEx, toCustomEitherEx)
import Presto.Backend.Playback.Types as Playback
import Presto.Backend.Playback.Entries as Playback
import Presto.Backend.Types.API (class RestEndpoint, Headers, makeRequest)
import Presto.Backend.Language.Types.DB (SqlConn, MockedSqlConn, KVDBConn, MockedKVDBConn, DBError(..), toDBMaybeResult, fromDBMaybeResult)
import Presto.Backend.Language.KVDB as KVDB
import Presto.Backend.Language.Types.KVDB as KVDB
import Presto.Backend.DB.Mock.Types as SqlDBMock
import Presto.Backend.DB.Mock.Actions as SqlDBMock
import Presto.Backend.KVDB.Mock.Types as KVDBMock
import Presto.Core.Types.Language.Interaction (Interaction)
import Sequelize.Class (class Model, class EncodeModel, class DecodeModel, encodeModel, decodeModel)
import Sequelize.Types (Conn, Instance, SEQUELIZE, ModelOf)

data BackendFlowCommands next st rt s
    = Ask (rt -> next)
    | Get (st -> next)
    | Put st (st -> next)
    | Modify (st -> st) (st -> next)

    | CallAPI (Interaction (EitherEx ErrorResponse s))
        (Playback.RRItemDict Playback.CallAPIEntry (EitherEx ErrorResponse s))
        (APIResult s -> next)

    | DoAff (forall eff. BackendAff eff s) (s -> next)

    | DoAffRR (forall eff. BackendAff eff s)
        (Playback.RRItemDict Playback.DoAffEntry s)
        (s -> next)

    | Log String s (Unit -> next)
    | Fork (BackendFlow st rt s) (Unit -> next)

    | RunSysCmd String
        (Playback.RRItemDict Playback.RunSysCmdEntry String)
        (String -> next)

    | ThrowException String

    | GetDBConn String
        (Playback.RRItemDict Playback.GetDBConnEntry SqlConn)
        (SqlConn -> next)

    | RunDB String
        (forall eff. Conn -> Aff (sequelize :: SEQUELIZE | eff) (EitherEx DBError s))
        (MockedSqlConn -> SqlDBMock.DBActionDict)
        (Playback.RRItemDict Playback.RunDBEntry (EitherEx DBError s))
        (EitherEx DBError s -> next)

    | GetKVDBConn String
      (Playback.RRItemDict Playback.GetKVDBConnEntry KVDBConn)
        (KVDBConn -> next)

    | RunKVDBEither String
        (KVDB.KVDB (EitherEx DBError s))
        (MockedKVDBConn -> KVDBMock.KVDBActionDict)
        (Playback.RRItemDict Playback.RunKVDBEntryEither (EitherEx DBError s))
        (EitherEx DBError s -> next)

    | RunKVDBSimple String
        (KVDB.KVDB s)
        (MockedKVDBConn -> KVDBMock.KVDBActionDict)
        (Playback.RRItemDict Playback.RunKVDBSimpleEntry s)
        (s -> next)

type BackendFlowCommandsWrapper st rt s next = BackendFlowCommands next st rt s

newtype BackendFlowWrapper st rt next = BackendFlowWrapper (Exists (BackendFlowCommands next st rt))

type BackendFlow st rt next = Free (BackendFlowWrapper st rt) next

wrap :: forall next st rt s. BackendFlowCommands next st rt s -> BackendFlow st rt next
wrap = liftF <<< BackendFlowWrapper <<< mkExists

ask :: forall st rt. BackendFlow st rt rt
ask = wrap $ Ask id

get :: forall st rt. BackendFlow st rt st
get = wrap $ Get id

put :: forall st rt. st -> BackendFlow st rt st
put st = wrap $ Put st id

modify :: forall st rt. (st -> st) -> BackendFlow st rt st
modify fst = wrap $ Modify fst id

callAPI
  :: forall st rt a b
   . Encode a
  => Encode b
  => Decode b
  => RestEndpoint a b
  => Headers -> a -> BackendFlow st rt (APIResult b)
callAPI headers a = wrap $ CallAPI
  (apiInteract a headers)
  (Playback.mkEntryDict (Playback.mkCallAPIEntry (defer $ \_ -> encodeJSON $ makeRequest a headers) ))
  id

doAff :: forall st rt a. (forall eff. BackendAff eff a) -> BackendFlow st rt a
doAff aff = wrap $ DoAff aff id

doAffRR
  :: forall st rt a
   . Encode a
  => Decode a
  => (forall eff. BackendAff eff a)
  -> BackendFlow st rt a
doAffRR aff = wrap $ DoAffRR aff (Playback.mkEntryDict Playback.mkDoAffEntry) id

log :: forall st rt a. String -> a -> BackendFlow st rt Unit
log tag message = wrap $ Log tag message id

forkFlow :: forall st rt a. BackendFlow st rt a -> BackendFlow st rt Unit
forkFlow flow = wrap $ Fork flow id

runSysCmd :: forall st rt. String -> BackendFlow st rt String
runSysCmd cmd = wrap $ RunSysCmd cmd (Playback.mkEntryDict $ Playback.mkRunSysCmdEntry cmd) id

throwException :: forall st rt a. String -> BackendFlow st rt a
throwException errorMessage = wrap $ ThrowException errorMessage

getDBConn :: forall st rt. String -> BackendFlow st rt SqlConn
getDBConn dbName = wrap $ GetDBConn dbName
  (Playback.mkEntryDict $ Playback.mkGetDBConnEntry dbName)
  id

findOne
  :: forall model st rt
   . Model model
  => String -> Options model -> BackendFlow st rt (Either Error (Maybe model))
findOne dbName options = do
  eResEx <- wrap $ RunDB dbName
    (\conn     -> toDBMaybeResult <$> DB.findOne conn options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkFindOne dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "findOne" [Opt.options options] (encode ""))
    id
  pure $ fromDBMaybeResult eResEx

findAll
  :: forall model st rt
   . Model model
  => String -> Options model -> BackendFlow st rt (Either Error (Array model))
findAll dbName options = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.findAll conn options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkFindAll dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "findAll" [Opt.options options] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

query
  :: forall r a st rt
   . Encode a
  => Decode a
  => Newtype a {|r}
  => String -> String -> BackendFlow st rt (Either Error (Array a))
query dbName rawq = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.query conn rawq)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkQuery dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "query" [toForeign rawq] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

create :: forall model st rt. Model model => String -> model -> BackendFlow st rt (Either Error (Maybe model))
create dbName model = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toDBMaybeResult <$> DB.create conn model)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkCreate dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "create" [] (encode model))
    id
  pure $ fromDBMaybeResult eResEx

createWithOpts :: forall model st rt. Model model => String -> model -> Options model -> BackendFlow st rt (Either Error (Maybe model))
createWithOpts dbName model options = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toDBMaybeResult <$> DB.createWithOpts conn model options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkCreateWithOpts dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "createWithOpts" [Opt.options options] (encode model))
    id
  pure $ fromDBMaybeResult eResEx

update :: forall model st rt. Model model => String -> Options model -> Options model -> BackendFlow st rt (Either Error (Array model))
update dbName updateValues whereClause = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.update conn updateValues whereClause)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkUpdate dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "update" [(Opt.options updateValues),(Opt.options whereClause)] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

update' :: forall model st rt. Model model => String -> Options model -> Options model -> BackendFlow st rt (Either Error Int)
update' dbName updateValues whereClause = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.update' conn updateValues whereClause)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkUpdate dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "update'" [(Opt.options updateValues),(Opt.options whereClause)] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

delete :: forall model st rt. Model model => String -> Options model -> BackendFlow st rt (Either Error Int)
delete dbName options = do
  eResEx <- wrap $ RunDB dbName
    (\conn -> toCustomEitherEx <$> DB.delete conn options)
    (\connMock -> SqlDBMock.mkDbActionDict $ SqlDBMock.mkDelete dbName)
    (Playback.mkEntryDict $ Playback.mkRunDBEntry dbName "delete" [Opt.options options] (encode ""))
    id
  pure $ fromCustomEitherEx eResEx

getKVDBConn :: forall st rt. String -> BackendFlow st rt KVDBConn
getKVDBConn dbName = wrap $ GetKVDBConn dbName
  (Playback.mkEntryDict $ Playback.mkGetKVDBConnEntry dbName)
  id

newMulti :: forall st rt. String -> BackendFlow st rt KVDB.Multi
newMulti dbName =
  wrap $ RunKVDBSimple dbName
    KVDB.newMulti
    KVDBMock.mkKVDBActionDict
    (Playback.mkEntryDict $ Playback.mkRunKVDBSimpleEntry dbName "newMulti" "")
    id

-- setCacheInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
-- setCacheInMulti key value multi = wrap $ SetCacheInMulti key value multi id
--
-- setCache :: forall st rt. String -> String ->  String -> BackendFlow st rt (Either Error Unit)
-- setCache dbName key value = do
--   cacheConn <- getCacheConn dbName
--   wrap $ SetCache cacheConn key value id
--
-- getCacheInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
-- getCacheInMulti key multi = wrap $ GetCacheInMulti key multi id
--
-- getCache :: forall st rt. String -> String -> BackendFlow st rt (Either Error (Maybe String))
-- getCache dbName key = do
--   cacheConn <- getCacheConn dbName
--   wrap $ GetCache cacheConn key id
--
-- keyExistsCache :: forall st rt. String -> String -> BackendFlow st rt (Either Error Boolean)
-- keyExistsCache dbName key = do
--   cacheConn <- getCacheConn dbName
--   wrap $ KeyExistsCache cacheConn key id
--
-- delCacheInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
-- delCacheInMulti key multi = wrap $ DelCacheInMulti key multi id
--
-- delCache :: forall st rt. String -> String -> BackendFlow st rt (Either Error Int)
-- delCache dbName key = do
--   cacheConn <- getCacheConn dbName
--   wrap $ DelCache cacheConn key id
--
-- setCacheWithExpireInMulti :: forall st rt. String -> String -> Milliseconds -> Multi -> BackendFlow st rt Multi
-- setCacheWithExpireInMulti key value ttl multi = wrap $ SetCacheWithExpiryInMulti key value ttl multi id
--
-- setCacheWithExpiry :: forall st rt. String -> String -> String -> Milliseconds -> BackendFlow st rt (Either Error Unit)
-- setCacheWithExpiry dbName key value ttl = do
--   cacheConn <- getCacheConn dbName
--   wrap $ SetCacheWithExpiry cacheConn key value ttl id
--
-- expireInMulti :: forall st rt. String -> Seconds -> Multi -> BackendFlow st rt Multi
-- expireInMulti key ttl multi = wrap $ ExpireInMulti key ttl multi id
--
-- expire :: forall st rt. String -> String -> Seconds -> BackendFlow st rt (Either Error Boolean)
-- expire dbName key ttl = do
--   cacheConn <- getCacheConn dbName
--   wrap $ Expire cacheConn key ttl id
--
-- incrInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
-- incrInMulti key multi = wrap $ IncrInMulti key multi id
--
-- incr :: forall st rt. String -> String -> BackendFlow st rt (Either Error Int)
-- incr dbName key = do
--   cacheConn <- getCacheConn dbName
--   wrap $ Incr cacheConn key id
--
-- setHashInMulti :: forall st rt. String -> String -> String -> Multi -> BackendFlow st rt Multi
-- setHashInMulti key field value multi = wrap $ SetHashInMulti key field value multi id
--
-- setHash :: forall st rt. String -> String -> String -> String -> BackendFlow st rt (Either Error Boolean)
-- setHash dbName key field value = do
--   cacheConn <- getCacheConn dbName
--   wrap $ SetHash cacheConn key field value id
--
-- getHashKeyInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
-- getHashKeyInMulti key field multi = wrap $ GetHashInMulti key field multi id
--
-- getHashKey :: forall st rt. String -> String -> String -> BackendFlow st rt (Either Error (Maybe String))
-- getHashKey dbName key field = do
--   cacheConn <- getCacheConn dbName
--   wrap $ GetHashKey cacheConn key field id
--
-- publishToChannelInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
-- publishToChannelInMulti channel message multi = wrap $ PublishToChannelInMulti channel message multi id
--
-- publishToChannel :: forall st rt. String -> String -> String -> BackendFlow st rt (Either Error Int)
-- publishToChannel dbName channel message = do
--   cacheConn <- getCacheConn dbName
--   wrap $ PublishToChannel cacheConn channel message id
--
-- subscribeToMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
-- subscribeToMulti channel multi = wrap $ SubscribeInMulti channel multi id
--
-- subscribe :: forall st rt. String -> String -> BackendFlow st rt (Either Error Unit)
-- subscribe dbName channel = do
--   cacheConn <- getCacheConn dbName
--   wrap $ Subscribe cacheConn channel id
--
-- enqueueInMulti :: forall st rt. String -> String -> Multi -> BackendFlow st rt Multi
-- enqueueInMulti listName value multi = wrap $ EnqueueInMulti listName value multi id
--
-- enqueue :: forall st rt. String -> String -> String -> BackendFlow st rt (Either Error Unit)
-- enqueue dbName listName value = do
--   cacheConn <- getCacheConn dbName
--   wrap $ Enqueue cacheConn listName value id
--
-- dequeueInMulti :: forall st rt. String -> Multi -> BackendFlow st rt Multi
-- dequeueInMulti listName multi = wrap $ DequeueInMulti listName multi id
--
-- dequeue :: forall st rt. String -> String -> BackendFlow st rt (Either Error (Maybe String))
-- dequeue dbName listName = do
--   cacheConn <- getCacheConn dbName
--   wrap $ Dequeue cacheConn listName id
--
-- getQueueIdxInMulti :: forall st rt. String -> Int -> Multi -> BackendFlow st rt Multi
-- getQueueIdxInMulti listName index multi = wrap $ GetQueueIdxInMulti listName index multi id
--
-- getQueueIdx :: forall st rt. String -> String -> Int -> BackendFlow st rt (Either Error (Maybe String))
-- getQueueIdx dbName listName index = do
--   cacheConn <- getCacheConn dbName
--   wrap $ GetQueueIdx cacheConn listName index id
--
-- execMulti :: forall st rt. Multi -> BackendFlow st rt (Either Error (Array Foreign))
-- execMulti multi = wrap $ Exec multi id
--
-- setMessageHandler :: forall st rt. String -> (forall eff. (String -> String -> Eff eff Unit)) -> BackendFlow st rt Unit
-- setMessageHandler dbName f = do
--   cacheConn <- getCacheConn dbName
--   wrap $ SetMessageHandler cacheConn f id

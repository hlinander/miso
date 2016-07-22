{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE PolyKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE DeriveFunctor             #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE StandaloneDeriving        #-}

module Miso where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.Free
import           Control.Monad.Free.TH
import           Data.Aeson                    hiding (Object)
import           Data.Bool
import qualified Data.Foldable                 as F
import           Data.IORef
import           Data.JSString.Text
import           Data.List                     (find)
import qualified Data.Map                      as M
import           Data.Maybe
import           Data.Monoid
import           Data.Proxy
import qualified Data.Set                      as S
import           Data.String.Conversions
import qualified Data.Text                     as T
import           FRP.Elerea.Simple             (externalMulti, transfer, start, effectful2)
import           GHC.Ptr
import           GHC.TypeLits
import           GHCJS.DOM
import           GHCJS.DOM.CharacterData
import           GHCJS.DOM.Document            hiding (drop, getLocation, focus)
import           GHCJS.DOM.Element             (removeAttribute, setAttribute, focus)
import           GHCJS.DOM.Event               (Event)
import qualified GHCJS.DOM.Event               as E
import           GHCJS.DOM.EventTarget         (addEventListener)
import           GHCJS.DOM.EventTargetClosures
import qualified GHCJS.DOM.Node                as Node
import           GHCJS.DOM.Node                hiding (getNextSibling)
import           GHCJS.DOM.NodeList            hiding (getLength)
import qualified GHCJS.DOM.Storage             as S
import           GHCJS.DOM.Types               hiding (Event, Attr)
import           GHCJS.DOM.Window              (getLocalStorage, getSessionStorage)
import           GHCJS.Foreign                 hiding (Object, Number)
import qualified GHCJS.Foreign.Internal        as Foreign
import           GHCJS.Marshal
import           GHCJS.Marshal.Pure
import qualified GHCJS.Types                   as G
import           JavaScript.Object.Internal
import           JavaScript.Web.AnimationFrame
import qualified Lucid                         as L
import qualified Lucid.Base                    as L
import           Miso.Types
import           Prelude                       hiding (repeat)

data Action object a where
  GetTarget :: object -> (object -> a) -> Action object a
  PreventDefault :: object -> a -> Action object a
  StopPropagation :: object -> a -> Action object a
  GetParent :: object -> (object -> a) -> Action object a
  GetField  :: FromJSON v => T.Text -> object -> (Maybe v -> a) -> Action object a
  GetChildren ::  object -> (object -> a) -> Action object a
  GetItem :: object -> Int -> (Maybe object -> a) -> Action object a
  GetNextSibling :: object -> (Maybe object -> a) -> Action object a

$(makeFreeCon 'GetTarget)
$(makeFreeCon 'GetParent)
$(makeFreeCon 'GetField)
$(makeFreeCon 'GetChildren)
$(makeFreeCon 'GetItem)
$(makeFreeCon 'GetNextSibling)
$(makeFreeCon 'PreventDefault)
$(makeFreeCon 'StopPropagation)

jsToJSON :: FromJSON v => JSType -> G.JSVal -> IO (Maybe v)
jsToJSON Foreign.Number  g = convertToJSON g
jsToJSON Foreign.Boolean g = convertToJSON g
jsToJSON Foreign.Object  g = convertToJSON g
jsToJSON Foreign.String  g = convertToJSON g
jsToJSON _ _ = pure Nothing

convertToJSON :: FromJSON v => G.JSVal -> IO (Maybe v)
convertToJSON g = do
  Just (val :: Value) <- fromJSVal g
  case fromJSON val of -- Should *always* be able to decode this
    Error e -> Prelude.error $ "Error while decoding Value: " <> e <> " " <> show val
    Success v -> pure (pure v)

evalEventGrammar :: Grammar G.JSVal a -> IO a
evalEventGrammar = do
  iterM $ \x ->
    case x of 
      GetTarget obj cb -> do
        cb =<< pToJSVal <$> E.getTarget (pFromJSVal obj :: E.Event)
      GetParent obj cb -> do
        Just p <- getParentNode (pFromJSVal obj :: Node)
        cb (pToJSVal p)
      GetField key obj cb -> do
        val <- getProp (textToJSString key) (Object obj)
        cb =<< jsToJSON (jsTypeOf val) val
      GetChildren obj cb -> do
        Just nodeList <- getChildNodes (pFromJSVal obj :: Node)
        cb $ pToJSVal nodeList
      GetItem obj n cb -> do
        result <- item (pFromJSVal obj :: NodeList) (fromIntegral n)
        cb $ pToJSVal <$> result
      GetNextSibling obj cb -> do
        result <- Node.getNextSibling (pFromJSVal obj :: Node) 
        cb $ pToJSVal <$> result
      StopPropagation obj cb -> do
        void $ E.stopPropagation (pFromJSVal obj :: E.Event)
        cb
      PreventDefault obj cb -> do
        void $ E.preventDefault (pFromJSVal obj :: E.Event)
        cb

deriving instance Functor (Action object)

type Grammar obj a = Free (Action obj) a

class HasEvent (eventName :: Symbol) returnType where
  parseEvent :: Proxy eventName -> obj -> Grammar obj returnType

on :: (KnownSymbol eventName, HasEvent eventName returnType)
   => Proxy eventName
   -> (returnType -> action)
   -> Attribute action
on p = EventHandler (symbolVal p) p

data Attribute action = forall eventName returnType . HasEvent eventName returnType =>
    EventHandler String (Proxy eventName) (returnType -> action)
  | Attr T.Text T.Text
  | Prop T.Text Value

instance Eq (Attribute action) where
  Prop x1 x2 == Prop y1 y2 = x1 == y1 && x2 == y2
  EventHandler x _ _ == EventHandler y _ _ = x == y
  _ == _                 = False

instance Show (Attribute action) where
  show (EventHandler name _ _) = "<event=" <> name <> ">"
  show (Attr k v) = T.unpack $ k <> "=" <> v
  show (Prop k v) = T.unpack $ k <> "=" <> T.pack (show v)

type VTree action = VTreeBase action (Maybe (Ptr ()))

toPtr :: Node -> Ptr ()
toPtr = G.toPtr . pToJSVal 

fromPtr :: Ptr a -> Node
fromPtr = pFromJSVal . G.fromPtr

toPtrFromEvent :: Event -> Ptr () 
toPtrFromEvent = G.toPtr . pToJSVal 

getKey :: VTreeBase action a -> Maybe Key
getKey (VNode _ _ _ maybeKey _) = maybeKey
getKey _ = Nothing

getKeyUnsafe :: VTreeBase action a -> Key
getKeyUnsafe (VNode _ _ _ (Just key) _) = key
getKeyUnsafe _ = Prelude.error "Key does not exist"

data VTreeBase action a where
  VNode :: T.Text -> [ Attribute action ] -> [ VTreeBase action a ] -> Maybe Key -> a -> VTreeBase action a 
  VText :: T.Text -> a -> VTreeBase action a 
  VEmpty :: VTreeBase action a
  deriving (Eq)

getChildDOMNodes :: VTree action -> [Node]
getChildDOMNodes (VNode _ _ children _ _) =
  [ fromPtr node | VNode _ _ _ _ (Just node) <- children ]
getChildDOMNodes _ = []

getDOMNode :: VTree action -> Maybe Node
getDOMNode (VNode _ _ _ _ ref) = fromPtr <$> ref
getDOMNode _ = Nothing

instance Show (VTreeBase action e) where
  show VEmpty = "<empty>"
  show (VText val _ ) = T.unpack val
  show (VNode typ evts children _ _) =
    "<" ++ T.unpack typ ++ ">" ++ show evts ++
      concatMap show children ++ "\n" ++ "</" ++ T.unpack typ ++ ">"

mkNode :: T.Text -> [Attribute action] -> [VTree action] -> VTree action
mkNode name as xs = VNode name as xs Nothing Nothing

newtype Key = Key T.Text deriving (Show, Eq, Ord)

mkNodeKeyed :: T.Text -> Key -> [Attribute action] -> [VTree action] -> VTree action
mkNodeKeyed name key as xs = VNode name as xs (Just key) Nothing

text_ :: T.Text -> VTree action
text_ = flip VText Nothing

div_ :: [Attribute action] -> [VTree action] -> VTree action
div_  = mkNode "div"

section_ :: [Attribute action] -> [VTree action] -> VTree action
section_  = mkNode "section"

header_ :: [Attribute action] -> [VTree action] -> VTree action
header_  = mkNode "header"

footer_ :: [Attribute action] -> [VTree action] -> VTree action
footer_  = mkNode "footer"

btn_ :: [Attribute action] -> [VTree action] -> VTree action
btn_ = mkNode "button"

class ExtractEvents (events :: [ (Symbol, Bool) ]) where
  extractEvents :: Proxy events -> [(T.Text, Bool)]

instance (ExtractEvents events, KnownSymbol event) =>
  ExtractEvents ('(event, 'True) ': events) where
    extractEvents _ = (eventName, True) : extractEvents (Proxy :: Proxy events)
      where
        eventName = T.pack $ symbolVal (Proxy :: Proxy event)

instance ( ExtractEvents events, KnownSymbol event ) =>
  ExtractEvents ('(event, 'False) ': events) where
    extractEvents _ = (eventName, False) : extractEvents (Proxy :: Proxy events)
      where
        eventName = T.pack $ symbolVal (Proxy :: Proxy event)

instance ExtractEvents '[] where extractEvents = const []
  
delegator
  :: forall action events . ExtractEvents events
  => (action -> IO ())
  -> IORef (VTree action)
  -> Proxy events
  -> IO ()
delegator writer ref Proxy = do
  Just doc <- currentDocument
  Just body <- fmap toNode <$> getBody doc
  listener <- eventListenerNew (f body)
  forM_ (extractEvents (Proxy :: Proxy events)) $ \(event, capture) ->
    addEventListener body event (Just listener) capture
    where
      f :: Node -> E.Event -> IO ()
      f body e = do
        Just target <- E.getTarget e
        vtree <- readIORef ref
        eventType :: String <- E.getType e
        stack <- buildTargetToBody body (castToNode target)
        delegateEvent e writer vtree eventType stack

buildTargetToBody :: Node -> Node -> IO [Node]
buildTargetToBody body target = f target [target]
    where
      f currentNode nodes
        | body == currentNode = pure (drop 2 nodes)
        | otherwise = do
            Just parent <- getParentNode currentNode
            f parent (parent:nodes)

runEvent
  :: HasEvent eventName returnType
  => Event
  -> (action -> IO ())
  -> Proxy eventName
  -> (returnType -> action)
  -> IO ()
runEvent e writer prox action = 
  writer =<< action <$> do
    evalEventGrammar $ parseEvent prox (pToJSVal e)


delegateEvent :: Event -> (action -> IO ()) -> VTree action -> String -> [Node] -> IO ()
delegateEvent e writer (VNode _ _ children _ _) eventName = findEvent children 
    where
      findEvent _ [] = pure ()
      findEvent childNodes [y] = 
       forM_ (findNode childNodes y) $ \(VNode _ attrs _ _ _) ->
         forM_ (getEventHandler attrs) $ \(EventHandler _ prox action) ->
           runEvent e writer prox action  

      findEvent childNodes (y:ys) = 
        forM_ (findNode childNodes y) $ \(VNode _ _ childrenNext _  _) ->
          findEvent childrenNext ys

      findNode childNodes ref = do
        let nodes = getVNodesOnly childNodes
        flip find nodes $ \node ->
          getDOMNode node == Just ref
  
      getVNodesOnly childs = do
        vnode@VNode{} <- childs
        pure vnode

      getEventHandler attrs =
       listToMaybe $ do
          eh@(EventHandler evtName _ _) <- attrs
          guard (evtName == eventName)
          pure eh
delegateEvent _ _ _ _ = const $ pure ()

initTree :: VTree action -> IO (VTree action)
initTree initial = do
  Just document <- currentDocument
  Just body <- getBody document
  vdom <- datch VEmpty initial
  case vdom of
    VText _ ref -> void $ appendChild body (fromPtr <$> ref)
    VNode _ _ _ _ ref -> void $ appendChild body (fromPtr <$> ref)
    VEmpty -> pure ()
  pure vdom

-- copies body first child into vtree, to avoid flickering
copyDOMIntoVTree :: Node -> VTree action -> IO (VTree action)
copyDOMIntoVTree _ VEmpty = pure VEmpty -- should never get called
copyDOMIntoVTree node (VText s _) = pure $ VText s (toPtr <$> Just node)
copyDOMIntoVTree node (VNode name attrs children key _) = do
  xs <- forM (zip [0 :: Int ..] children) $ \(index, childNode) -> do
          Just childNodes <- getChildNodes node
          Just child <- item childNodes (fromIntegral index)
          copyDOMIntoVTree child childNode
  pure $ VNode name attrs xs key (toPtr <$> Just node)

datch :: VTree action -> VTree action -> IO (VTree action)
datch currentTree newTree = do
  Just document <- currentDocument
  Just body <- fmap toNode <$> getBody document
  goDatch document body currentTree newTree

goDatch :: Document -> Node -> VTree action -> VTree action -> IO (VTree action)
goDatch _ _ VEmpty VEmpty = pure VEmpty

-- Ensure correct initialization (always true if internal)
goDatch _ _ (VNode _ _ _ _ Nothing) _ = Prelude.error "VNode not initialized"
goDatch _ _ (VText _ Nothing) _ = Prelude.error "VText not initialized"

-- Make a new text node
goDatch doc parentNode VEmpty (VText str _) = do
  newTextNode <- createTextNode doc str
  void $ appendChild parentNode newTextNode
  pure $ VText str (toPtr <$> toNode <$> newTextNode)

-- Remove a text node
goDatch _ parentNode (VText _ node) VEmpty = do
  void $ removeChild parentNode (fromPtr <$> node)
  pure VEmpty

-- Make a new element
goDatch doc parentNode VEmpty (VNode typ attrs children key _) = do
  node@(Just newNode)  <- fmap toNode <$> createElement doc (Just typ)
  void $ diffAttrs newNode [] attrs
  newChildren <- forM children $ \childNode ->
    goDatch doc newNode VEmpty childNode
  void $ appendChild parentNode node
  pure $ VNode typ attrs newChildren key (toPtr <$> node)

-- Remove an element
goDatch _ parentNode (VNode _ _ _ _ node) VEmpty = 
  VEmpty <$ removeChild parentNode (fromPtr <$> node)

-- Replace an element with a text node
goDatch doc parentNode (VNode _ _ _ _ ref) (VText str _) = do
  newTextNode <- fmap toNode <$> createTextNode doc str
  void $ replaceChild parentNode newTextNode (fromPtr <$> ref)
  pure $ VText str (toPtr <$> newTextNode)

-- Replace a text node with an Element
goDatch doc parentNode (VText _ ref) (VNode typ attrs children key _) = do
  node@(Just newNode) <- fmap toNode <$> createElement doc (Just typ)
  newChildren <- forM children $ \childNode ->
    goDatch doc newNode VEmpty childNode
  void $ replaceChild parentNode node (fromPtr <$> ref)
  pure $ VNode typ attrs newChildren key (toPtr <$> node)

-- Replace a text node with a text node
goDatch _ _ (VText currentStr currRef) (VText newStr _) = do
  when (currentStr /= newStr) $ do
    F.forM_ currRef $ \ref -> do
      let txt = castToText (fromPtr ref)
      oldLength <- getLength txt
      replaceData txt 0 oldLength newStr
  pure $ VText newStr currRef

-- Diff two nodes together
goDatch doc parent
  (VNode typA attrsA childrenA _ (Just ref))
  (VNode typB attrsB childrenB keyB _) = do
 case typA == typB of
   True ->
      VNode typB <$> diffAttrs (fromPtr ref) attrsA attrsB
                 <*> diffChildren doc (fromPtr ref) childrenA childrenB
                 <*> pure keyB
                 <*> pure (Just ref)
   False -> do      
      node@(Just newNode) <- fmap toNode <$> createElement doc (Just typB)
      void $ diffAttrs newNode [] attrsB
      newChildren <- forM childrenB $ \childNode ->
        goDatch doc newNode VEmpty childNode
      void $ replaceChild parent node (fromPtr <$> Just ref)
      pure $ VNode typB attrsB newChildren keyB (toPtr <$> node)

instance L.ToHtml (VTree action) where
  toHtmlRaw = L.toHtml
  toHtml VEmpty = Prelude.error "VEmpty for internal use only"
  toHtml (VText x _) = L.toHtml x
  toHtml (VNode typ attrs children _ _) =
    let ele = L.makeElement (toTag typ) (foldMap L.toHtml children)
    in L.with ele as
      where
        as = [ L.makeAttribute k v | Attr k v <- attrs ]
        toTag = T.toLower

diffAttrs
  :: Node
  -> [Attribute action]
  -> [Attribute action]
  -> IO [Attribute action]
diffAttrs node attrsA attrsB = do
  when (attrsA /= attrsB) $ diffPropsAndAttrs node attrsA attrsB
  pure attrsB

observables :: M.Map T.Text (Element -> IO ())
observables = M.fromList [("autofocus", focus)]

dispatchObservable :: T.Text -> Element -> IO ()
dispatchObservable key el = do
  F.forM_ (M.lookup key observables) $ \f -> f el

diffPropsAndAttrs :: Node -> [Attribute action] -> [Attribute action] -> IO ()
diffPropsAndAttrs node old new = do
  obj <- Object <$> toJSVal node
  let el = castToElement node
      
      newAttrs = S.fromList [ (k, v) | Attr k v <- new ]
      oldAttrs = S.fromList [ (k, v) | Attr k v <- old ]

      removeAttrs = oldAttrs `S.difference` newAttrs
      addAttrs    = newAttrs `S.difference` oldAttrs

      newProps = M.fromList [ (k,v) | Prop k v <- new ]
      oldProps = M.fromList [ (k,v) | Prop k v <- old ]

      propsToRemove = oldProps `M.difference` newProps
      propsToAdd    = newProps `M.difference` oldProps
      propsToDiff   = newProps `M.intersection` oldProps

  forM_ (M.toList propsToRemove) $ \(k, _) -> do
    setProp (textToJSString k) jsNull obj

  forM_ (M.toList propsToAdd) $ \(k, v) -> do
    val <- toJSVal v
    setProp (textToJSString k) val obj

  forM_ (M.toList propsToDiff) $ \(k, _) -> do
    case (M.lookup k oldProps, M.lookup k newProps) of
      (Just oldVal, Just newVal) ->
        when (oldVal /= newVal) $ do
        val <- toJSVal newVal
        setProp (textToJSString k) val obj
        dispatchObservable k el
      (_, _) -> pure ()

  forM_ removeAttrs $ \(k,_) -> removeAttribute el k 
  forM_ addAttrs $ \(k,v) -> setAttribute el k v

isKeyed :: [VTree action] -> Bool
isKeyed [] = False
isKeyed (x : _) = hasKey x
  where
    hasKey :: VTree action -> Bool
    hasKey (VNode _ _ _ (Just _) _) = True
    hasKey _ = False

makeMap :: [VTree action] -> M.Map Key (VTree action)
makeMap vs = M.fromList [ (key, v) | v@(VNode _ _ _ (Just key) _) <- vs ]

diffChildren 
  :: Document
  -> Node
  -> [VTree action]
  -> [VTree action]
  -> IO [VTree action]
diffChildren doc parent as bs = do
  case isKeyed as of
    True -> do
      swappedKids <- swapKids parent (makeMap as) as (makeMap bs) bs
      xs <- diffChildren' doc parent swappedKids bs
      pure $ filter (/=VEmpty) xs
    False -> do
      xs <- diffChildren' doc parent as bs
      pure $ filter (/=VEmpty) xs

diffChildren'
  :: Document
  -> Node
  -> [VTree action]
  -> [VTree action]
  -> IO [VTree action]
diffChildren' _ _ [] [] = pure []
diffChildren' doc parent [] (b:bs) = 
  (:) <$> goDatch doc parent VEmpty b
      <*> diffChildren doc parent [] bs
diffChildren' doc parent (a:as) [] = 
  (:) <$> goDatch doc parent a VEmpty
      <*> diffChildren doc parent as [] 
diffChildren' doc parent (a:as) (b:bs) = do
  (:) <$> goDatch doc parent a b
      <*> diffChildren doc parent as bs

type Events = Proxy [(Symbol, Bool)]

runSignal :: forall e action . ExtractEvents e => Proxy e -> (action -> IO ()) -> Signal (VTree action) -> IO ()
runSignal events writer (Signal s) = do
  vtreeRef <- newIORef =<< initTree VEmpty
  _ <- forkIO $ delegator writer vtreeRef events 
  emitter <- start s
  forever $ 
    waitForAnimationFrame >>
      emitter >>= \case
        Changed [ newTree ] -> do
          patchedTree <- (`datch` newTree) =<< readIORef vtreeRef
          writeIORef vtreeRef patchedTree
        _ -> pure ()

signal :: Show a => a -> IO (Signal a, a -> IO ())
signal x = do
  (s, writer) <- externalMulti 
  writer x
  pure (Signal $ fmap toSample <$> s, writer)
    where
      toSample [] = NotChanged []
      toSample xs = Changed xs

getFromStorage
  :: FromJSON model
  => T.Text
  -> IO (Either String model)
getFromStorage key = do
  Just w <- currentWindow
  Just s <- getLocalStorage w
  maybeVal <- S.getItem s key
  pure $ case maybeVal of
    Nothing -> Left "Not found"
    Just m -> eitherDecode (cs (m :: T.Text))

data DebugModel 
data DebugActions
data SaveToLocalStorage (key :: Symbol)
data SaveToSessionStorage (key :: Symbol)

instance Show model => ToAction model actions DebugModel where
  toAction _ _ m = print m

instance Show actions => ToAction model actions DebugActions where
  toAction _ as _ = print as

instance (ToJSON model, KnownSymbol sym, Show model) =>
  ToAction model actions (SaveToSessionStorage sym) where
  toAction _ _ m = do
    let key = T.pack $ symbolVal (Proxy :: Proxy sym)
    Just w <- currentWindow
    Just s <- getSessionStorage w
    S.setItem s (textToJSString key) (cs (encode m) :: T.Text)

instance (ToJSON model, KnownSymbol sym, Show model) 
  => ToAction model actions (SaveToLocalStorage sym) where
  toAction _ _ m = do
    let key = T.pack $ symbolVal (Proxy :: Proxy sym)
    Just w <- currentWindow
    Just s <- getLocalStorage w
    S.setItem s (textToJSString key) (cs (encode m) :: T.Text)

instance HasAction model action '[] where
    performActions _ _ _ = pure ()

instance (Nub (c ': cs) ~ (c ': cs), HasAction model action cs, ToAction model action c, Show model)
  => HasAction model action (c ': cs) where
    performActions _ as m = 
      toAction nextAction as m >>
        performActions nextActions as m
          where
            nextAction :: Proxy c; nextActions :: Proxy cs
            nextActions = Proxy; nextAction = Proxy

class Nub config ~ config => HasAction model action config where
  performActions :: Proxy config -> [action] -> model -> IO ()

class ToAction model action config where
  toAction :: Proxy config -> [action] -> model -> IO ()

foldp :: forall model action config . ( HasAction model action config, Eq model )
      => Proxy config
      -> (action -> model -> model)
      -> model
      -> Signal action
      -> Signal model
foldp p f ini (Signal gen) = do
   Signal $ gen >>= \as -> transfer (pure [ini]) update as
                >>= \ms -> effectful2 (handleEffects p) as ms
     where
        handleEffects _ (Changed as) m@(Changed [model]) = 
          performActions p as model >> pure m
        handleEffects _ _ m = pure m
        update (NotChanged _) xs = NotChanged (fromChanged xs)
        update (Changed actions) model = do
          let [ oldModel ] = fromChanged model
              newModel = foldr f oldModel (reverse actions)
          case oldModel == newModel of
            True -> NotChanged [ oldModel ]
            False -> Changed [ newModel ]

attr :: T.Text -> T.Text -> Attribute action
attr = Attr

prop :: ToJSON a => T.Text -> a -> Attribute action 
prop k v = Prop k (toJSON v)

boolProp :: T.Text -> Bool -> Attribute action 
boolProp = prop

stringProp :: T.Text -> T.Text -> Attribute action
stringProp = prop

textProp :: T.Text -> T.Text -> Attribute action
textProp = prop

intProp :: T.Text -> Int -> Attribute action
intProp = prop

integerProp :: T.Text -> Integer -> Attribute action
integerProp = prop

doubleProp :: T.Text -> Double -> Attribute action
doubleProp = prop

checked_ :: Bool -> Attribute action
checked_ = boolProp "checked"

form_ :: [Attribute action] -> [VTree action] -> VTree action
form_ = mkNode "form" 

p_ :: [Attribute action] -> [VTree action] -> VTree action
p_ = mkNode "p" 

s_ :: [Attribute action] -> [VTree action] -> VTree action
s_ = mkNode "s" 

ul_ :: [Attribute action] -> [VTree action] -> VTree action
ul_ = mkNode "ul" 

span_ :: [Attribute action] -> [VTree action] -> VTree action
span_ = mkNode "span" 

strong_ :: [Attribute action] -> [VTree action] -> VTree action
strong_ = mkNode "strong" 

li_ :: [Attribute action] -> [VTree action] -> VTree action
li_ = mkNode "li" 

liKeyed_ :: Key -> [Attribute action] -> [VTree action] -> VTree action
liKeyed_ = mkNodeKeyed "li" 

h1_ :: [Attribute action] -> [VTree action] -> VTree action
h1_ = mkNode "h1" 

input_ :: [Attribute action] -> [VTree action] -> VTree action
input_ = mkNode "input" 

label_ :: [Attribute action] -> [VTree action] -> VTree action
label_ = mkNode "label" 

a_ :: [Attribute action] -> [VTree action] -> VTree action
a_ = mkNode "a" 

style_ :: T.Text -> Attribute action 
style_ = attr "style" 

type_ :: T.Text -> Attribute action 
type_ = attr "type"

name_ :: T.Text -> Attribute action 
name_ = attr "name"

href_ :: T.Text -> Attribute action 
href_ = attr "href"

className_ :: T.Text -> Attribute action 
className_ = stringProp "className"

class_ :: T.Text -> Attribute action 
class_ = attr "class"

id_ :: T.Text -> Attribute action 
id_ = attr "id"

placeholder :: T.Text -> Attribute action 
placeholder = attr "placeholder" 

autofocus :: Bool -> Attribute action 
autofocus = boolProp "autofocus"

template :: VTree action
template = div_  [] []

-- | (EventName, Capture)

defaultEvents :: Proxy '[
    '("blur", 'True)
  , '("change", 'False)
  , '("click", 'False)
  , '("dblclick", 'False)
  , '("focus", 'False)
  , '("input", 'False)
  , '("keydown", 'False)
  , '("keypress", 'False)
  , '("keyup", 'False)
  , '("mouseup", 'False)
  , '("mousedown", 'False)
  , '("mouseenter", 'False)
  , '("mouseleave", 'False)
  , '("mouseover", 'False)
  , '("mouseout", 'False)
  , '("submit", 'False)
  ]
defaultEvents = Proxy 

instance HasEvent "blur" () where parseEvent _ _ = pure ()
instance HasEvent "change" Bool where parseEvent _ = checkedGrammar
instance HasEvent "click" () where parseEvent _ _ = pure ()
instance HasEvent "dblclick" () where parseEvent _ _ = pure ()
instance HasEvent "focus" () where parseEvent _ _ = pure ()
instance HasEvent "input" T.Text where parseEvent _ = inputGrammar
instance HasEvent "keydown" Int where parseEvent _ = keyGrammar
instance HasEvent "keypress" Int where parseEvent _ = keyGrammar
instance HasEvent "keyup" Int where parseEvent _ = keyGrammar
instance HasEvent "mouseup" () where parseEvent _ _ = pure ()
instance HasEvent "mousedown" () where parseEvent _ _ = pure ()
instance HasEvent "mouseenter" () where parseEvent _ _ = pure ()
instance HasEvent "mouseleave" () where parseEvent _ _ = pure ()
instance HasEvent "mouseover" () where parseEvent _ _ = pure ()
instance HasEvent "mouseout" () where parseEvent _ _ = pure ()
instance HasEvent "submit" () where parseEvent _ = preventDefault 

onBlur :: action -> Attribute action
onBlur action = on (Proxy :: Proxy "blur") $ \() -> action

onChecked :: (Bool -> action) -> Attribute action
onChecked = on (Proxy :: Proxy "change")

onClick :: action -> Attribute action
onClick action = on (Proxy :: Proxy "click") $ \() -> action

onFocus :: action -> Attribute action
onFocus action = on (Proxy :: Proxy "focus") $ \() -> action

onDoubleClick :: action -> Attribute action
onDoubleClick action = on (Proxy :: Proxy "dblclick") $ \() -> action

onInput :: (T.Text -> action) -> Attribute action
onInput = on (Proxy :: Proxy "input")

onKeyDown :: (Int -> action) -> Attribute action
onKeyDown = on (Proxy :: Proxy "keydown")

onKeyPress :: (Int -> action) -> Attribute action
onKeyPress = on (Proxy :: Proxy "keypress")

onKeyUp :: (Int -> action) -> Attribute action
onKeyUp = on (Proxy :: Proxy "keyup")

onMouseUp :: action -> Attribute action
onMouseUp action = on (Proxy :: Proxy "mouseup") $ \() -> action

onMouseDown :: action -> Attribute action
onMouseDown action = on (Proxy :: Proxy "mousedown") $ \() -> action

onMouseEnter :: action -> Attribute action
onMouseEnter action = on (Proxy :: Proxy "mouseenter") $ \() -> action

onMouseLeave :: action -> Attribute action
onMouseLeave action = on (Proxy :: Proxy "mouseleave") $ \() -> action

onMouseOver :: action -> Attribute action
onMouseOver action = on (Proxy :: Proxy "mouseover") $ \() -> action

onMouseOut :: action -> Attribute action
onMouseOut action = on (Proxy :: Proxy "mouseout") $ \() -> action

onSubmit :: action -> Attribute action
onSubmit action = on (Proxy :: Proxy "submit") $ \() -> action

inputGrammar :: FromJSON a => obj -> Grammar obj a 
inputGrammar e = do
    target <- getTarget e
    result <- getField "value" target
    case result of
      Nothing -> Prelude.error "Couldn't retrieve target input value"
      Just value -> pure value

checkedGrammar :: FromJSON a => obj -> Grammar obj a 
checkedGrammar e = do
    target <- getTarget e
    result <- getField "checked" target
    case result of
      Nothing -> Prelude.error "Couldn't retrieve target checked value"
      Just value -> pure value

keyGrammar :: FromJSON a => obj -> Grammar obj a 
keyGrammar e = do   
    keyCode <- getField "keyCode" e
    which <- getField "which" e
    charCode <- getField "charCode" e
    pure $ head $ catMaybes [ keyCode, which, charCode ]

type family Nub t where
  Nub '[]           = '[]
  Nub '[e]          = '[e]
  Nub (e ': e ': s) = (e ': s)
  Nub (e ': f ': s) = e ': Nub (f ': s)

swapKids
  :: Node
  -> M.Map Key (VTree action)
  -> [ VTree action ]
  -> M.Map Key (VTree action)
  -> [ VTree action ]
  -> IO [ VTree action ]
swapKids _ _ [] _ [] = pure []

-- | No nodes left, remove all remaining
swapKids p currentMap (c:ccs) newMap [] = do
  let VNode _ _ _ _ currentNode = c
  void $ removeChild p $ fromPtr <$> currentNode
  swapKids p currentMap ccs newMap []

-- | Add remaining new nodes
swapKids p currentMap [] newMap (new:nns) = do
  newNode <- renderNode p new
  ts <- swapKids p currentMap [] newMap nns
  pure $ newNode : ts

swapKids p currentMap (c:ccs) newMap (new:nns) = do
  case getKey c == getKey new of 
    -- Keys same, continue
    True -> do
      ts <- swapKids p currentMap ccs newMap nns
      pure (c:ts)
    -- Keys not the same, check if current node has been moved or deleted
    False -> do
      case M.lookup (getKeyUnsafe c) newMap of
        -- Current node has been deleted, remove from DOM
        Nothing -> do
          let VNode _ _ _ _ node = c
          void $ removeChild p $ fromPtr <$> node
          swapKids p currentMap ccs newMap (new:nns)
        -- Current node exists, but does new node exist in current map?
        Just _ -> do
          let VNode _ _ _ _ currentNode = c
          case M.lookup (getKeyUnsafe new) currentMap of
            -- New node, doesn't exist in current map, create new node and insertBefore
            Nothing -> do
              newNode@(VNode _ _ _ _  node) <- renderDontAppend new
              void $ insertBefore p (fromPtr <$> currentNode) (fromPtr <$> node) 
              ts <- swapKids p currentMap (c:ccs) newMap nns
              pure $ newNode : ts
            -- Node has moved, use insertBefore on moved node
            Just n -> do
              let VNode _ _ _ _ movedNode = n
              void $ insertBefore p (fromPtr <$> currentNode) (fromPtr <$> movedNode) 
              ts <- swapKids p currentMap ccs newMap nns
              pure $ n : ts 

renderNode :: Node -> VTree action -> IO (VTree action)
renderNode parent (VNode typ attrs children key _) = do
  Just doc <- currentDocument
  Just node <- fmap toNode <$> createElement doc (Just typ)
  void $ diffAttrs node [] attrs
  newChildren <- forM children $ \childNode ->
    goDatch doc node VEmpty childNode
  void $ appendChild parent (Just node)
  pure $ VNode typ attrs newChildren key (toPtr <$> Just node)
renderNode parent (VText str _) = do
  Just doc <- currentDocument
  newTextNode <- createTextNode doc str
  void $ appendChild parent newTextNode
  pure $ VText str (toPtr <$> toNode <$> newTextNode)
renderNode _ _ = pure VEmpty

renderDontAppend :: VTree action -> IO (VTree action)
renderDontAppend (VNode typ attrs children key _) = do
  Just doc <- currentDocument
  Just node <- fmap toNode <$> createElement doc (Just typ)
  void $ diffAttrs node [] attrs
  newChildren <- forM children $ \childNode ->
    goDatch doc node VEmpty childNode
  pure $ VNode typ attrs newChildren key (toPtr <$> Just node)
renderDontAppend (VText str _) = do
  Just doc <- currentDocument
  newTextNode <- createTextNode doc str
  pure $ VText str (toPtr <$> toNode <$> newTextNode)
renderDontAppend _ = pure VEmpty
  
class ToKey key where toKey :: key -> Key
instance ToKey String  where toKey = Key . T.pack 
instance ToKey T.Text  where toKey = Key
instance ToKey Int where toKey = Key . T.pack . show
instance ToKey Double where toKey = Key . T.pack . show
instance ToKey Float where toKey = Key . T.pack . show
instance ToKey Word where toKey = Key . T.pack . show
instance ToKey Key where toKey = id



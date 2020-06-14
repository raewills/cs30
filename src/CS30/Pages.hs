{-# LANGUAGE DeriveFunctor   #-}
{-# LANGUAGE TemplateHaskell #-}
module CS30.Pages where
import           CS30.Data
import           CS30.Exercises
import           CS30.Sessions
import           CS30.Util
import           Control.Monad.IO.Class
import           Control.Monad.Trans.State.Lazy
import           Data.Aeson as JSON
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Map as Map
import           Data.Maybe
import qualified Data.Text.Lazy as Text
import           System.Random

pageLookup :: String -> Maybe ExerciseType
pageLookup = flip Map.lookup $ Map.fromList (map (\et -> (etTag et,et)) (pages ++ tests))

-- | Handle a response from an exercise
handleExResponse :: String -> SesIO Rsp
handleExResponse s
 = case decode (L8.pack s) of
     Nothing -> err500 $ "Decoding error: "++s
     Just (v@ExResponse{})
       -> case pageLookup (exTag v) of
            Nothing -> err500 $ "The exercise-type you just made ("++exTag v++") appears to have been removed or renamed - it is no longer recognised by the server"
            Just et -> do let handler = getHandler (cAction v) et
                          exerciseResponse et (exId v) (cValue v) handler (fmap snd . handler (cValue v) . lrProblem)

getHandler
    :: Action
    -> ExerciseType
    -> Map.Map String String
    -> LevelProblem
    -> SesIO (ProblemResolve, Rsp)
getHandler _ et usr lp
 = do let pr = (etGenAns et) (lpPuzzelQst lp) (lpPuzzelSol lp) usr
      return (ProblemResolve lp usr (prOutcome pr),mempty{rSplash = Just (SplashPR pr)})

exerciseResponse :: ExerciseType
                 -> Int
                 -> Map.Map String String
                 -> (Map.Map String String -> LevelProblem -> SesIO (ProblemResolve, b))
                 -> (ProblemResolve -> SesIO b)
                 -> SesIO b
exerciseResponse et eid usrData handleCur handleStale'
 = do let nm = etTag et
      ses <- get
      let lDat = sdLevelData ses
      case Map.lookup nm lDat of
        Just ld -> case ldOpenProblem ld of
                     Just lp -> if lpPuzzelID lp == eid then
                                  do (reslv,rsp) <- handleCur usrData lp
                                     let newD = (case lrScore reslv of
                                                  POCorrect -> 
                                                    increaseLevel
                                                    ld{ ldStreakPerLevel = udNth ((+) 1) (lpLevel lp) (ldStreakPerLevel ld)
                                                      , ldRightPerLevel = udNth ((+) 1) (lpLevel lp) (ldRightPerLevel ld)
                                                      }
                                                  POIncorrect -> 
                                                    resetLevel
                                                    ld{ ldStreakPerLevel = udNth (const 0) (lpLevel lp) (ldStreakPerLevel ld)
                                                      , ldWrongPerLevel = udNth ((+) 1) (lpLevel lp) (ldWrongPerLevel ld)
                                                      }
                                                ){ ldOpenProblem = Nothing
                                                 , ldPastProblems = reslv{lrUserAnswer = usrData}:ldPastProblems ld}
                                     put ses{sdLevelData=Map.insert nm newD lDat}
                                     return rsp
                                else handleStale (ldPastProblems ld)
                     Nothing -> handleStale (ldPastProblems ld)
        Nothing -> handleStale []
 where handleStale (a:as) = if lpPuzzelID (lrProblem a) == eid then handleStale' a
                            else handleStale as
       handleStale [] = err500 ("The exercise id "++show eid++" is was not found in your profile")
       increaseLevel ld
        = let cl = ldCurrentLevel ld
              drop' = drop cl
              nl = nextUp (drop' $ ldStreakPerLevel ld)
                          (drop' $ ldWrongPerLevel ld)
                          (drop' $ ldRightPerLevel ld)
          in ld{ldCurrentLevel = cl + nl}
       resetLevel ld = ld{ldCurrentLevel = nextUpStrk (ldStreakPerLevel ld)}
       nextUp strk wrongs rights
        = if head0 rights > 3 * head0 wrongs then 1 + nextUpStrk (drop 1 strk) else nextUpStrk strk
       nextUpStrk (c:lst) | c >= 10 = 1 + nextUpStrk lst
       nextUpStrk _ = 0
       udNth f n lst | n > 0 = head0 lst : udNth f n (drop 1 lst)
        | otherwise = f (head0 lst):drop 1 lst
       head0 lst = head (lst ++ [0])
{-
data ExResponse
      = ExResponse {cAction :: Action
                   ,cValue  :: Map.Map String String
                   ,exId    :: Int
                   ,exTag   :: String}

  
data ExerciseType
  = ExerciseType{ etTag :: String
                , etMenu :: String
                , etTitle :: String
                , etChoices :: [ChoiceTree (Text.Text, Text.Text)]
                , etGenEx :: (Text.Text -> Exercise -> Exercise)
                , etGenAns :: (Text.Text -> Text.Text -> Map.Map String String -> ProblemResponse)
                }
  -}

-- | Populate the response with exercises based on the requested page. If there is no page, a listing is returned
populateEx :: Maybe String -> SesIO Rsp
populateEx (Just ('?':str)) = populateEx (Just str)
populateEx (Just str@(_:_)) | Just etp <- pageLookup str
 = do exc <- paintExercise etp
      return mempty{rExercises = [exc]}
populateEx _ = return mempty

mkPage :: ExerciseType -> Page
mkPage etp = Page (etTag etp) (etMenu etp ++ " - " ++ etTitle etp)

handleResponse :: Map.Map String [String] -- POST data
               -> (String, ClientLink) -> IO ()
handleResponse mp (sesnr, clientLink)
 = do let search = listToMaybe =<< Map.lookup "s" mp -- 's' is used when looking for a page (example: 'ex1')
      let exResponse = concat . maybeToList$ Map.lookup "ex" mp :: [String] -- 'ex' is used when responding to an exercise. json-encoded.
      hasEmail <- obtainEmail clientLink
      rsp <- runWithLink hasEmail clientLink$
             foldl (<>) mempty{rSes=sesnr,rLogin=hasEmail} <$> sequenceA
              (  [populateEx search]
              ++ [handleExResponse rsp | rsp <- exResponse]
              ++ [ return mempty{rPages = map mkPage pages}
                 | "page" <- concat . maybeToList $ Map.lookup "cAct" mp]
              )
      respond rsp{rEcho = listToMaybe =<< Map.lookup "echo" mp}
 where
    respond :: Rsp -> IO ()
    respond rsp = do putStrLn "Content-type: application/json\n"
                     L8.putStrLn (JSON.encode rsp)
                     return ()

-- | Get a random thing from a tree
randomSelect :: MonadIO m => ChoiceTree a -> m ([Int], a)
randomSelect (Branch lst)
  = do nr <- liftIO$ randomRIO (0,length lst-1)
       (is,a) <- randomSelect (lst!!nr)
       return (nr:is,a)
randomSelect (Node a) = return ([], a)

-- | Select a puzzle (either the most recent or a randomly selected one),
-- | store the answer in the Ses for later processing (if necessary),
-- | return the selected puzzle and its ID.
-- | This function is also where the automated level selection comes in
smartSelect :: String
            -> [ChoiceTree (Text.Text, Text.Text)]
            -> SesIO (Int, Text.Text)
smartSelect nm lst
  = do ses <- get
       let ld = fromMaybe (defaultLevelData (length lst)) $ Map.lookup nm (sdLevelData ses)
       case ldOpenProblem ld of
         Nothing -> do let lvl = ldCurrentLevel ld
                       let maxL = length lst - 1
                       (genInfo,(puzzleQ,puzzleS))
                         <- if lvl > maxL
                            then randomSelect (Branch lst)
                            else randomSelect (lst !! lvl)
                       let nextNr = case ldPastProblems ld of
                                      (a:_) -> 1+lpPuzzelID (lrProblem a)
                                      _ -> 0
                       let newProblem = LevelProblem {lpPuzzelID=nextNr
                                                     ,lpLevel=if lvl > maxL then head genInfo else lvl
                                                     ,lpPuzzelGen=genInfo
                                                     ,lpPuzzelQst=puzzleQ
                                                     ,lpPuzzelSol=puzzleS
                                                     }
                       -- store the problem:
                       let ld' = Map.insert nm ld{ldOpenProblem = Just newProblem} (sdLevelData ses)
                       put (ses{sdLevelData = ld'})
                       return (nextNr, puzzleQ)
         Just v -> return (lpPuzzelID v, (lpPuzzelQst v))

paintExercise :: ExerciseType -> SesIO Exercise
paintExercise et
 = do (eid,ex) <- smartSelect (etTag et) (etChoices et)
      let dex = defaultExercise{ eTopic = etTitle et, eActions = [Check]
                               , eHidden = [ FValueS "tag" "ExerciseType"
                                           , FValue "exId" eid
                                           , FValueS "exTag" (etTag et) ]}
      return (etGenEx et ex dex)
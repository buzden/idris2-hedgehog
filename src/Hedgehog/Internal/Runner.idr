module Hedgehog.Internal.Runner

import Data.Colist
import Data.Cotree
import Data.IORef
import Data.List
import Hedgehog.Internal.Config
import Hedgehog.Internal.Gen
import Hedgehog.Internal.Options
import Hedgehog.Internal.Property
import Hedgehog.Internal.Range
import Hedgehog.Internal.Report
import Hedgehog.Internal.Seed
import Hedgehog.Internal.Terminal
import System

%default total

public export
TestRes : Type
TestRes = (Either Failure (), Journal)

--------------------------------------------------------------------------------
--          Shrinking
--------------------------------------------------------------------------------

-- Shrinking
shrink : Monad m => Nat -> Coforest a -> b -> (Nat -> a -> m (Maybe b)) -> m b
shrink _     []        b _ = pure b
shrink 0 _             b _ = pure b
shrink (S k) (t :: ts) b f = do Just b2 <- f (S k) t.value
                                  | Nothing => shrink k ts b f
                                shrink k t.forest b2 f

takeSmallest :
     Monad m
  => Size
  -> Seed
  -> ShrinkLimit
  -> (Progress -> m ())
  -> Cotree TestRes
  -> m Result
takeSmallest si se (MkTagged slimit) updateUI t =
  do res <- run 0 t.value
     if isFailure res
        then shrink slimit t.forest res runMaybe
        else pure res

  where
    -- calc number of shrinks from the remaining
    -- allowed numer and the shrink limit
    calcShrinks : Nat -> ShrinkCount
    calcShrinks rem = MkTagged $ (slimit `minus` rem) + 1

    run : ShrinkCount -> TestRes -> m Result
    run shrinks t =
      case t of
        (Left $ MkFailure err diff, MkJournal logs) =>
           let fail = mkFailure si se shrinks Nothing err diff (reverse logs)
            in updateUI (Shrinking fail) $> Failed fail

        (Right x, _) => pure OK

    runMaybe : Nat -> TestRes -> m (Maybe Result)
    runMaybe shrinksLeft testRes =
      do res <- run (calcShrinks shrinksLeft) testRes
         if isFailure res then pure (Just res) else pure Nothing

--------------------------------------------------------------------------------
--          Test Runners
--------------------------------------------------------------------------------

-- main test runner
checkReport :
     Monad m
  => PropertyConfig
  -> Size
  -> Seed
  -> PropertyT ()
  -> (Report Progress -> m ())
  -> m (Report Result)
checkReport cfg si0 se0 test updateUI =
  let (conf, MkTagged numTests) = unCriteria cfg.terminationCriteria
   in loop numTests 0 si0 se0 neutral conf

  where
    loop :  Nat
         -> TestCount
         -> Size
         -> Seed
         -> Coverage CoverCount
         -> Maybe Confidence
         -> m (Report Result)
    loop n tests si se cover conf = do
      updateUI (MkReport tests cover Running)
      case n of
        0   =>
          -- required number of tests run
          pure $ report False tests si se cover conf
        S k =>
          if abortEarly cfg.terminationCriteria tests cover conf
             then
               -- at this point we know that enough
               -- tests have been run due to early termination
               pure $ report True tests si se cover conf
             else
              -- run another test
              let (s0,s1) = split se
                  tr      = runGen si s0 $ runTestT test
                  nextSize = if si < maxSize then (si + 1) else 0
               in case tr.value of
                    -- the test failed, so we abort and shrink
                    (Left x, _)  =>
                      let upd = updateUI . MkReport (tests+1) cover
                       in map (MkReport (tests+1) cover) $
                            takeSmallest si se cfg.shrinkLimit upd tr

                    -- the test succeeded, so we accumulate results
                    -- and loop once more
                    (Right x, journal) =>
                      let cover1 = journalCoverage journal <+> cover
                       in loop k (tests + 1) nextSize s1 cover1 conf

checkTerm :  HasIO io
          => Terminal
          -> UseColor
          -> Maybe PropertyName
          -> Size
          -> Seed
          -> Property
          -> io (Report Result)
checkTerm term color name si se prop =
  do result <- checkReport {m = io} prop.config si se prop.test $ \prog =>
               if multOf100 prog.tests
                  then let ppprog = renderProgress color name prog
                        in case prog.status of
                               Running     => putTmp term ppprog
                               Shrinking _ => putTmp term ppprog
                  else pure ()

     putOut term (renderResult color name result)
     pure result

checkWith :  HasIO io
          => Terminal
          -> UseColor
          -> Maybe PropertyName
          -> Property
          -> io (Report Result)
checkWith term color name prop =
  initSMGen >>= \se => checkTerm term color name 0 se prop

||| Check a property.
export
checkNamed : HasIO io => PropertyName -> Property -> io Bool
checkNamed name prop = do
  color <- detectColor
  term  <- console
  rep   <- checkWith term color (Just name) prop
  pure $ rep.status == OK

||| Check a property.
export
check : HasIO io => Property -> io Bool
check prop = do
  color <- detectColor
  term  <- console
  rep   <- checkWith term color Nothing prop
  pure $ rep.status == OK

||| Check a property using a specific size and seed.
export
recheck : HasIO io => Size -> Seed -> Property -> io ()
recheck si se prop = do
  color <- detectColor
  term  <- console
  _     <- checkTerm term color Nothing si se (withTests 1 prop)
  pure ()

checkGroupWith :  Terminal
               -> UseColor
               -> List (PropertyName, Property)
               -> IO Summary
checkGroupWith term color = run neutral
  where run : Summary -> List (PropertyName, Property) -> IO Summary
        run s [] = pure s
        run s ((pn,p) :: ps) = do rep  <- checkWith term color (Just pn) p
                                  run (s <+> fromResult rep.status) ps

export
checkGroup : HasIO io => Group -> io Bool
checkGroup (MkGroup group props) =
  do term    <- console
     putOut term $ "━━━ " ++ unTag group ++ " ━━━"
     color   <- detectColor
     summary <- liftIO $ checkGroupWith term color props
     putOut term (renderSummary color summary)
     pure $ summary.failed == 0

||| Simple test runner.
|||
||| Use this in a `main` function in order to test a list of
||| property groups. The runner will take into account several
||| command line arguments in order to adjust the number of
||| tests to be run for each property, the maximal number of
||| shrinks and the confidence value to use.
|||
||| ```idris example
||| main : IO ()
||| main = test myGroups
||| ```
|||
||| The resulting executable can then be run as follows:
|||
||| ```sh
||| build/exec/runTests -n 1000
||| ```
|||
||| It will fail with an exit code of 1 if at least one property
||| fails.
export
test : HasIO io => List Group -> io ()
test gs = do
  args    <- getArgs
  Right c <- pure $ applyArgs args
    | Left errs => do
        putStrLn "Errors when parsing command line args:"
        traverse_ putStrLn errs
        exitFailure
  if c.printHelp
     then putStrLn info >> exitSuccess
     else
       let gs2 = map (applyConfig c) gs
        in do
             res <- foldlM (\b,g => map (b &&) (checkGroup g)) True gs2
             if res
                then exitSuccess
                else putStrLn "\n\nSome tests failed" >> exitFailure

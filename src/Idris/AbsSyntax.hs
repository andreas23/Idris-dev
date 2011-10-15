{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, DeriveFunctor,
             TypeSynonymInstances #-}

module Idris.AbsSyntax where

import Core.TT
import Core.Evaluate

import Control.Monad.State
import Data.List
import Data.Char
import Debug.Trace

import qualified Epic.Epic as E

data IOption = IOption { opt_logLevel :: Int }
    deriving (Show, Eq)

defaultOpts = IOption 0

-- TODO: Add 'module data' to IState, which can be saved out and reloaded quickly (i.e
-- without typechecking).
-- This will include all the functions and data declarations, plus fixity declarations
-- and syntax macros.

data IState = IState { tt_ctxt :: Context,
                       idris_infixes :: [FixDecl],
                       idris_implicits :: Ctxt [PArg],
                       idris_log :: String,
                       idris_options :: IOption,
                       idris_name :: Int,
                       imported :: [FilePath],
                       idris_prims :: [(Name, ([E.Name], E.Term))]
                     }
                   
idrisInit = IState emptyContext [] emptyContext "" defaultOpts 0 [] []

-- The monad for the main REPL - reading and processing files and updating 
-- global state (hence the IO inner monad).
type Idris a = StateT IState IO a

getContext :: Idris Context
getContext = do i <- get; return (tt_ctxt i)

getIState :: Idris IState
getIState = get

putIState :: IState -> Idris ()
putIState = put

getName :: Idris Int
getName = do i <- get;
             let idx = idris_name i;
             put (i { idris_name = idx + 1 })
             return idx

setContext :: Context -> Idris ()
setContext ctxt = do i <- get; put (i { tt_ctxt = ctxt } )

updateContext :: (Context -> Context) -> Idris ()
updateContext f = do i <- get; put (i { tt_ctxt = f (tt_ctxt i) } )

iputStrLn :: String -> Idris ()
iputStrLn = lift.putStrLn

setLogLevel :: Int -> Idris ()
setLogLevel l = do i <- get
                   let opts = idris_options i
                   let opt' = opts { opt_logLevel = l }
                   put (i { idris_options = opt' } )

logLevel :: Idris Int
logLevel = do i <- get
              return (opt_logLevel (idris_options i))

logLvl :: Int -> String -> Idris ()
logLvl l str = do i <- get
                  let lvl = opt_logLevel (idris_options i)
                  when (lvl >= l)
                      $ do lift (putStrLn str)
                           put (i { idris_log = idris_log i ++ str ++ "\n" } )

iLOG :: String -> Idris ()
iLOG = logLvl 1

-- Commands in the REPL

data Command = Quit | Help | Eval PTerm 
             | Compile String
             | TTShell 
             | NOP

-- Parsed declarations

data Fixity = Infixl { prec :: Int } 
            | Infixr { prec :: Int }
            | InfixN { prec :: Int } 
            | PrefixN { prec :: Int }
    deriving Eq

instance Show Fixity where
    show (Infixl i) = "infixl " ++ show i
    show (Infixr i) = "infixr " ++ show i
    show (InfixN i) = "infix " ++ show i
    show (PrefixN i) = "prefix " ++ show i

data FixDecl = Fix Fixity String 
    deriving (Show, Eq)

instance Ord FixDecl where
    compare (Fix x _) (Fix y _) = compare (prec x) (prec y)

data Plicity = Imp | Exp deriving Show

data PDecl' t = PFix     Fixity [String] -- fixity declaration
              | PTy      Name t          -- type declaration
              | PClauses Name [PClause' t]    -- pattern clause
              | PData    (PData' t)      -- data declaration
              | PParams  [(Name, PTerm)] [PDecl' t] -- params block
              | PImport  String
    deriving Functor

data PClause' t = PClause Name t t [PDecl]
    deriving Functor

data PData' t  = PDatadecl { d_name :: Name,
                             d_tcon :: t,
                             d_cons :: [(Name, t)] }
    deriving Functor

-- Handy to get a free function for applying PTerm -> PTerm functions
-- across a program, by deriving Functor

type PDecl   = PDecl' PTerm
type PData   = PData' PTerm
type PClause = PClause' PTerm 

-- get all the names declared in a decl

declared :: PDecl -> [Name]
declared (PFix _ _) = []
declared (PTy n t) = [n]
declared (PClauses n _) = [] -- not a declaration
declared (PData (PDatadecl n _ ts)) = n : map fst ts
declared (PParams _ ds) = concatMap declared ds
declared (PImport _) = []

-- High level language terms
--
data PTerm = PQuote Raw
           | PRef Name
           | PLam Name PTerm PTerm
           | PPi  Plicity Name PTerm PTerm
           | PLet Name PTerm PTerm PTerm -- not implemented yet
           | PApp PTerm [PArg]
           | PTrue
           | PFalse
           | PPair PTerm PTerm
           | PHidden PTerm -- irrelevant or hidden pattern
           | PSet
           | PConstant Const
           | Placeholder

data PArg' t = PImp { pname :: Name, getTm :: t }
             | PExp { getTm :: t }
    deriving (Show, Functor)

type PArg = PArg' PTerm

-- Syntactic sugar info (TODO: namespaces, parameters, modules)

data SyntaxInfo = Syn { using :: [(Name, PTerm)],
                        syn_params :: [(Name, PTerm)] }
    deriving Show

defaultSyntax = Syn [] []

--- Pretty printing declarations and terms

instance Show PTerm where
    show tm = showImp False tm

instance Show PDecl where
    show (PFix f ops) = show f ++ " " ++ showSep ", " ops
    show (PTy n ty) = show n ++ " : " ++ show ty
    show (PClauses n c) = showSep "\n" (map show c)
    show (PData d) = show d

instance Show PClause where
    show c = showCImp False c

instance Show PData where
    show d = showDImp False d

showCImp :: Bool -> PClause -> String
showCImp impl (PClause n l r w) = showImp impl l ++ " = " ++ showImp impl r
                                    ++ " where " ++ show w 
showDImp :: Bool -> PData -> String
showDImp impl (PDatadecl n ty cons) 
   = "data " ++ show n ++ " : " ++ showImp impl ty ++ " where\n\t"
     ++ showSep "\n\t| " 
            (map (\ (n, t) -> show n ++ " : " ++ showImp impl t) cons)

getImps :: [PArg] -> [(Name, PTerm)]
getImps [] = []
getImps (PImp n tm : xs) = (n, tm) : getImps xs
getImps (_ : xs) = getImps xs

getExps :: [PArg] -> [PTerm]
getExps [] = []
getExps (PExp tm : xs) = tm : getExps xs
getExps (_ : xs) = getExps xs

getAll :: [PArg] -> [PTerm]
getAll = map getTm 

showImp :: Bool -> PTerm -> String
showImp impl tm = se 10 tm where
    se p (PQuote r) = "![" ++ show r ++ "]"
    se p (PRef n) = show n
    se p (PLam n ty sc) = bracket p 2 $ "\\ " ++ show n ++ " => " ++ show sc
    se p (PPi Exp n ty sc)
        | n `elem` allNamesIn sc = bracket p 2 $
                                    "(" ++ show n ++ " : " ++ se 10 ty ++ 
                                    ") -> " ++ se 10 sc
        | otherwise = bracket p 2 $ se 0 ty ++ " -> " ++ se 10 sc
    se p (PPi Imp n ty sc)
        | impl = bracket p 2 $ "{" ++ show n ++ " : " ++ se 10 ty ++ 
                               "} -> " ++ se 10 sc
        | otherwise = se 10 sc
    se p (PApp (PRef f) [])
        | not impl = show f
    se p (PApp (PRef op@(UN [f:_])) args)
        | length (getExps args) == 2 && not impl && not (isAlpha f) 
            = let [l, r] = getExps args in
              bracket p 1 $ se 1 l ++ " " ++ show op ++ " " ++ se 0 r
    se p (PApp f as) 
        = let (imps, args) = (getImps as, getExps as) in
              bracket p 1 $ se 1 f ++ (if impl then concatMap siArg imps else "")
                                   ++ concatMap seArg args
    se p (PHidden tm) = "." ++ se 0 tm
    se p PTrue = "()"
    se p PFalse = "_|_"
    se p (PPair l r) = "(" ++ se 10 l ++ ", " ++ se 10 r ++ ")"
    se p PSet = "Set"
    se p (PConstant c) = show c
    se p Placeholder = "_"

    seArg arg      = " " ++ se 0 arg
    siArg (n, val) = " {" ++ show n ++ " = " ++ se 10 val ++ "}"

    bracket outer inner str | inner > outer = "(" ++ str ++ ")"
                            | otherwise = str

allNamesIn :: PTerm -> [Name]
allNamesIn tm = nub $ ni [] tm 
  where
    ni env (PRef n)        
        | not (n `elem` env) = [n]
    ni env (PApp f as)  = ni env f ++ concatMap (ni env) (map getTm as)
    ni env (PLam n ty sc)  = ni env ty ++ ni (n:env) sc
    ni env (PPi _ n ty sc) = ni env ty ++ ni (n:env) sc
    ni env (PHidden tm)    = ni env tm
    ni env _               = []

namesIn :: IState -> PTerm -> [Name]
namesIn ist tm = nub $ ni [] tm 
  where
    ni env (PRef n)        
        | not (n `elem` env) 
            = case lookupCtxt n (idris_implicits ist) of
                Nothing -> [n]
                _ -> []
    ni env (PApp f as)  = ni env f ++ concatMap (ni env) (map getTm as)
    ni env (PLam n ty sc)  = ni env ty ++ ni (n:env) sc
    ni env (PPi _ n ty sc) = ni env ty ++ ni (n:env) sc
    ni env (PHidden tm)    = ni env tm
    ni env _               = []

-- For inferring types of things

inferTy   = MN 0 "__Infer"
inferCon  = MN 0 "__infer"
inferDecl = PDatadecl inferTy 
                      PSet
                      [(inferCon, PPi Imp (MN 0 "A") PSet (
                                  PPi Exp (MN 0 "a") (PRef (MN 0 "A"))
                                  (PRef inferTy)))]

infTerm t = PApp (PRef inferCon) [PImp (MN 0 "A") Placeholder, PExp t]
infP = P (TCon 0) inferTy (Set 0)

getInferTerm, getInferType :: Term -> Term
getInferTerm (Bind n b sc) = Bind n b $ getInferTerm sc
getInferTerm (App (App _ _) tm) = tm
getInferTerm tm = error ("getInferTerm " ++ show tm)

getInferType (Bind n b sc) = Bind n b $ getInferType sc
getInferType (App (App _ ty) _) = ty

-- Handy primitives: Unit, False, Pair, MkPair

unitTy   = MN 0 "__Unit"
unitCon  = MN 0 "__II"
unitDecl = PDatadecl unitTy PSet
                     [(unitCon, PRef unitTy)]

falseTy   = MN 0 "__False"
falseDecl = PDatadecl falseTy PSet []

pairTy    = MN 0 "__Pair"
pairCon   = MN 0 "__MkPair"
pairDecl  = PDatadecl pairTy (piBind [(n "A", PSet), (n "B", PSet)] PSet)
            [(pairCon, PPi Imp (n "A") PSet (
                       PPi Imp (n "B") PSet (
                       PPi Exp (n "a") (PRef (n "A")) (
                       PPi Exp (n "b") (PRef (n "B"))  
                           (PApp (PRef pairTy) [PExp (PRef (n "A")),
                                                PExp (PRef (n "B"))])))))]
    where n a = MN 0 a

piBind :: [(Name, PTerm)] -> PTerm -> PTerm
piBind [] t = t
piBind ((n, ty):ns) t = PPi Exp n ty (piBind ns t)

-- Dealing with implicit arguments

-- Add implicit Pi bindings for any names in the term which appear in an
-- argument position.

implicitise :: SyntaxInfo -> IState -> PTerm -> (PTerm, [PArg])
implicitise syn ist tm
    = let uvars = using syn
          pvars = syn_params syn
          (declimps, ns') = execState (imps True [] tm) ([], []) 
          ns = ns' \\ map fst pvars in
          if null ns 
            then (tm, reverse declimps) 
            else implicitise syn ist (pibind uvars ns tm)
  where
    imps top env (PApp f as)
       = do (decls, ns) <- get
            let isn = concatMap (namesIn ist) (map getTm as)
            put (decls, nub (ns ++ (isn \\ (env ++ map fst (getImps decls)))))
    imps top env (PPi Imp n ty sc) 
        = do let isn = namesIn ist ty \\ [n]
             (decls , ns) <- get
             put (PImp n ty : decls, nub (ns ++ (isn \\ (env ++ map fst (getImps decls)))))
             imps True (n:env) sc
    imps top env (PPi Exp n ty sc) 
        = do let isn = (namesIn ist ty ++ case sc of
                            (PRef x) -> namesIn ist sc
                            _ -> []) \\ [n]
             (decls, ns) <- get -- ignore decls in HO types
             put (PExp ty : decls, nub (ns ++ (isn \\ (env ++ map fst (getImps decls)))))
             imps True (n:env) sc
    imps top env (PLam n ty sc)  
        = do imps False env ty
             imps False (n:env) sc
    imps top env (PHidden tm)    = imps False env tm
    imps top env _               = return ()

    pibind using []     sc = sc
    pibind using (n:ns) sc = case lookup n using of
                               Just ty -> PPi Imp n ty (pibind using ns sc)
                               Nothing -> PPi Imp n Placeholder (pibind using ns sc)

-- Add implicit arguments in function calls

addImpl :: IState -> PTerm -> PTerm
addImpl ist ptm = ai [] ptm
  where
    ai env (PRef f)       = aiFn env (PRef f) []
    ai env (PApp (PRef f) as) 
                          = let as' = map (fmap (ai env)) as in
                                aiFn env (PRef f) as'
    ai env (PApp f as)    = let f' = ai env f
                                as' = map (fmap (ai env)) as in
                                      aiFn env f' as'
    ai env (PLam n ty sc) = let ty' = ai env ty
                                sc' = ai (n:env) sc in
                                PLam n ty' sc'
    ai env (PPi p n ty sc) = let ty' = ai env ty
                                 sc' = ai (n:env) sc in
                                 PPi p n ty' sc'
    ai env (PHidden tm) = PHidden (ai env tm)
    ai env tm = tm

    aiFn env (PRef f) as | not (f `elem` env)
        = case lookupCtxt f (idris_implicits ist) of
            Just ns -> pApp (length ns) (PRef f) (insertImpl ns as)
            Nothing -> pApp 1 (PRef f) as
    aiFn env f as = pApp 1 f as

    pApp a f [] = f
    pApp a f as = let rest = drop a as in
                      appRest (PApp f (take a as)) rest

    appRest f [] = f
    appRest f (a : as) = appRest (PApp f [a]) as

    insertImpl :: [PArg] -> [PArg] -> [PArg]
    insertImpl (PExp ty : ps) (PExp tm : given) =
                                 PExp tm : insertImpl ps given
    insertImpl (PImp n ty : ps) given =
        case find n given [] of
            Just (tm, given') -> PImp n ty : insertImpl ps given'
            Nothing ->           PImp n Placeholder : insertImpl ps given
    insertImpl expected [] = []
    insertImpl []       given  = given

    find n []               acc = Nothing
    find n (PImp n' t : gs) acc 
         | n == n' = Just (t, reverse acc ++ gs)
    find n (g : gs) acc = find n gs (g : acc)

-- Debugging/logging stuff

dumpDecls :: [PDecl] -> String
dumpDecls [] = ""
dumpDecls (d:ds) = dumpDecl d ++ "\n" ++ dumpDecls ds

dumpDecl (PFix f ops) = show f ++ " " ++ showSep ", " ops 
dumpDecl (PTy n t) = "tydecl " ++ show n ++ " : " ++ showImp True t
dumpDecl (PClauses n cs) = "pat\t" ++ showSep "\n\t" (map (showCImp True) cs)
dumpDecl (PData d) = showDImp True d
dumpDecl (PParams ns ps) = "params {" ++ show ns ++ "\n" ++ dumpDecls ps ++ "}\n"
dumpDecl (PImport i) = "import " ++ i

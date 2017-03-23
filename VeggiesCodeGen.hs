{-# LANGUAGE TupleSections #-}
{-# LANGUAGE StandaloneDeriving #-}
module VeggiesCodeGen where

import Data.List
import Data.Maybe
import Control.Monad.State
import Control.Monad.Writer

import Var
import Id
import Module
import Type
import TyCon
import DataCon
import Name
import OccName
import CoreSyn
import CoreUtils
import CoreFVs
import Encoding
import Outputable
import PrelNames
import TysWiredIn
import BasicTypes
import VarSet

import Ollvm_ast

import Debug.Trace

type GenEnv = IdSet

genCode :: ModuleName -> [TyCon] -> CoreProgram -> Coq_modul
genCode name tycons binds
    = mkCoqModul (moduleNameString name)
      (concat globals)
      defaultTyDecls
      decls
      (defaultDefs ++ catMaybes defs)
  where
    env = top_level_ids
    top_level_ids = mkVarSet (bindersOfBinds binds')
    binds' = (NonRec tupDCId (Var tupDCId)) :  binds
    (globals, defs) = unzip [genStaticVal env v e | (v,e) <- flattenBinds binds', isWanted v]

    tupDCId = dataConWorkId (tupleDataCon Unboxed 2)
    decls = [ mallocDecl, topHandlerDecl ]

defaultTyDecls :: [Coq_type_decl]
defaultTyDecls =
    [ Coq_mk_type_decl (Name "hs")    mkClosureTy
    , Coq_mk_type_decl (Name "thunk") (mkThunkTy 0)
    , Coq_mk_type_decl (Name "dc")    (mkDataConTy 0)
    ]

defaultDefs :: [Coq_definition]
defaultDefs =
    [ returnArgDef
    ]

returnArgDef :: Coq_definition
returnArgDef = mkEnterFunDefinition
    LINKAGE_Private
    "returnArg"
    (runG $ returnFromFunction (ID_Local (Name "clos")))

returnArgIdent :: Coq_ident
returnArgIdent = ID_Global (Name "returnArg")

mkClosureTy :: Coq_typ
mkClosureTy = TYPE_Struct [ enterFunTyP ]

hsTy :: Coq_typ
hsTy = TYPE_Identified (ID_Global (Name "hs"))

hsTyP :: Coq_typ
hsTyP = TYPE_Pointer (TYPE_Identified (ID_Global (Name "hs")))

-- An explicit, global function to call
hsFunTy :: Int -> Int -> Coq_typ
hsFunTy n m = TYPE_Function hsTyP (envTyP m : replicate n hsTyP)

-- Entering a closure
enterFunTy  = TYPE_Function hsTyP [hsTyP]
enterFunTyP = TYPE_Pointer enterFunTy

mkThunkTy :: Int -> Coq_typ
mkThunkTy n = TYPE_Struct [ enterFunTyP, TYPE_Array n' hsTyP ]
  where n' = max 1 n

thunkTy :: Coq_typ
thunkTy = TYPE_Identified (ID_Global (Name "thunk"))

thunkTyP :: Coq_typ
thunkTyP = TYPE_Pointer thunkTy

tagTy = TYPE_I 64
tagTyP = TYPE_Pointer tagTy

arityTy = TYPE_I 64

mkDataConTy n = TYPE_Struct [ enterFunTyP, tagTy, TYPE_Array n hsTyP ]

envTy m = TYPE_Array m hsTyP
envTyP m = TYPE_Pointer (envTy m)

mkFunClosureTy n m =
    TYPE_Struct [ enterFunTyP
                , TYPE_Pointer (hsFunTy n m)
                , arityTy
                , envTy m
                ]

dataConTy = TYPE_Identified (ID_Global (Name "dc"))
dataConTyP = TYPE_Pointer dataConTy

-- Lets filter out typeable stuff for now
isWanted :: Var -> Bool
isWanted v | Just (tc,_) <- splitTyConApp_maybe (varType v)
           , getUnique tc `elem` [ trNameTyConKey, trTyConTyConKey, trModuleTyConKey]
           = False
isWanted v = True

genStaticVal :: GenEnv -> Var -> CoreExpr -> ([Coq_global], Maybe Coq_definition)
genStaticVal env v rhs
    | idArity v == 0
    , Just dc <- isDataConId_maybe v
    =
    let val = SV $VALUE_Struct [ (enterFunTyP,                     ident returnArgIdent)
                               , (TYPE_I 64, SV (VALUE_Integer (dataConTag dc)))
                               , (envTy 0 , SV (VALUE_Array []))
                               ]
    in ( [ Coq_mk_global
               (varRawId v)
               (mkDataConTy 0) --hsTyP
               True -- constant
               (Just val)
               (Just LINKAGE_External)
               Nothing
               Nothing
               Nothing
               False
               Nothing
               False
               Nothing
               Nothing
         ]
       , Nothing )
genStaticVal env v rhs
    | (Var f, args) <- collectArgs rhs
    , Just dc <- isDataConId_maybe f
    , let val_args = filter isValArg args
    , not (null val_args)
    =
    let args_idents = [ (hsTyP, cast (idArity v) (ident (varIdent env v)))
                      | Var v <- val_args ]
        arity = length args_idents
        val = SV $VALUE_Struct [ (enterFunTyP,                     ident returnArgIdent)
                               , (TYPE_I 64, SV (VALUE_Integer (dataConTag dc)))
                               , (envTy arity , SV (VALUE_Array args_idents))
                               ]
    in (if length args_idents == dataConRepArity dc then id
           else pprTrace "genStaticVal arity" (ppr v <+> ppr arity <+> ppr dc))
       ( [ Coq_mk_global
             (varRawId v)
             (mkDataConTy arity) --hsTyP
             True -- constant
             (Just val)
             (Just LINKAGE_External)
             Nothing
             Nothing
             Nothing
             False
             Nothing
             False
             Nothing
             Nothing
          ]
        , Nothing)
  where
    cast arity val = SV (OP_Conversion Bitcast (mkDataConTy arity) val hsTyP)

genStaticVal env v rhs =
    ( [ Coq_mk_global
          (varRawId v)
          (mkFunClosureTy arity 0) --hsTyP
          True -- constant
          (Just val)
          (Just linkage)
          Nothing
          Nothing
          Nothing
          False
          Nothing
          False
          Nothing
          Nothing
      ]
    , Just $ genTopLvlFunction env v rhs)
  where
    linkage | Just dc <- isDataConId_maybe v, isUnboxedTupleCon dc
            = LINKAGE_Private
            | otherwise
            = LINKAGE_External
    arity = idArity v
    val = SV $VALUE_Struct [ (enterFunTyP,                     ident returnArgIdent)
                           , (TYPE_Pointer (hsFunTy arity 0) , ident (funIdent env v))

                           , (TYPE_I 64, SV (VALUE_Integer arity))
                           , (envTy 0 , SV (VALUE_Array []))
                      ]
    -- casted_val = SV $ OP_Conversion Bitcast (mkFunClosureTy arity 0) val hsTy

genTopLvlFunction :: GenEnv -> Id -> CoreExpr -> Coq_definition
genTopLvlFunction env v rhs
    | Just dc <- isDataConWorkId_maybe v = genDataConWorker dc
genTopLvlFunction env v rhs =
    mkHsFunDefinition
        linkage
        (funRawId v)
        [ varRawId p | p <- params ]
        (runG (genExpr env body >>= returnFromFunction))
  where
    (params, body) = collectMoreValBinders rhs
    linkage | Just dc <- isDataConId_maybe v, isUnboxedTupleCon dc
            = LINKAGE_Private
            | otherwise
            = LINKAGE_External

genMalloc :: Coq_typ -> G Coq_ident
genMalloc t = do
    -- http://stackoverflow.com/a/30830445/946226
    offset <- emitInstr $ INSTR_Op (SV (OP_GetElementPtr t (t, SV VALUE_Null) [(TYPE_I 32, SV (VALUE_Integer 1))]))
    size <- emitInstr $ INSTR_Op (SV (OP_Conversion Ptrtoint t (ident offset) (TYPE_I 64)))
    emitInstr $ INSTR_Call (mallocTy, ID_Global (Name "malloc")) [(TYPE_I 64, ident size)]

allocateDataCon :: Coq_raw_id -> DataCon -> (G (), [Coq_ident] ->  G ())
allocateDataCon dcName dc = (alloc, fill)
  where
    alloc = do
        dcRawPtr <- genMalloc thisDataConTyP
        emitNamedInstr dcName $
            INSTR_Op (SV (OP_Conversion Bitcast mallocRetTyP (ident dcRawPtr) hsTyP))

    fill args = do
        let dcClosure = ID_Local dcName
        dcCasted <- emitInstr $
            INSTR_Op (SV (OP_Conversion Bitcast hsTyP (ident dcClosure) thisDataConTyP))

        codePtr <- emitInstr $ getElemPtr thisDataConTyP dcCasted [0,0]
        emitInstr $ INSTR_Store False (enterFunTyP, ident codePtr) (enterFunTyP, ident returnArgIdent) Nothing

        tagPtr <- emitInstr $ getElemPtr thisDataConTyP dcCasted [0,1]
        emitInstr $ INSTR_Store False (tagTyP, ident tagPtr) (tagTy, SV (VALUE_Integer (dataConTag dc))) Nothing

        forM_ (zip [0..] args) $ \(n, arg) -> do
            p <- emitInstr $ getElemPtr thisDataConTyP dcCasted [0,2,n]
            emitInstr $ INSTR_Store False (hsTyP, ident p) (hsTyP, ident arg) Nothing

    thisDataConTy = mkDataConTy (dataConRepArity dc)
    thisDataConTyP = TYPE_Pointer thisDataConTy

genDataConWorker :: DataCon -> Coq_definition
genDataConWorker dc = mkHsFunDefinition linkage
    (funRawId (dataConWorkId dc))
    [ Name (paramName n) | n <- [0.. dataConRepArity dc-1]] $
    runG $ do
        let (alloc, fill) = allocateDataCon (Name "dc") dc
        alloc
        fill [ ID_Local (Name (paramName n)) | n <- [0..dataConRepArity dc - 1]]
        returnFromFunction (ID_Local (Name "dc"))
  where
    linkage | isUnboxedTupleCon dc
            = LINKAGE_Private
            | otherwise
            = LINKAGE_External

    paramName n = "dcArg_" ++ show n

mallocRetTyP = TYPE_Pointer (TYPE_I 8)
mallocTy = TYPE_Function mallocRetTyP [TYPE_I 64]

mallocDecl ::  Coq_declaration
mallocDecl = Coq_mk_declaration
    (Name "malloc")
    mallocTy
    ([],[[]])
    Nothing
    Nothing
    Nothing
    Nothing
    []
    Nothing
    Nothing
    Nothing


topHandlerDecl :: Coq_declaration
topHandlerDecl = mkHsFunDeclaration LINKAGE_External (Name "GHCziTopHandler_runMainIO") [Name "main"]

-- A code generation monad
type G a = StateT Int (Writer [Coq_terminator -> Coq_block]) a

deriving instance Show Coq_raw_id
deriving instance Show Coq_type_decl
deriving instance Show Coq_typ
deriving instance Show Coq_ident
deriving instance Show Coq_fn_attr
deriving instance Show Coq_linkage
deriving instance Show Coq_dll_storage
deriving instance Show Coq_cconv
deriving instance Show Coq_declaration
deriving instance Show Coq_param_attr
deriving instance Show Coq_visibility
deriving instance Show Coq_icmp
deriving instance Show Coq_ibinop
deriving instance Show Coq_fcmp
deriving instance Show Coq_fbinop
deriving instance Show Coq_fast_math
deriving instance Show Coq_conversion_type
deriving instance Show a => Show (Ollvm_ast.Expr a)
deriving instance Show Coq_value
deriving instance Show Coq_terminator
deriving instance Show Coq_instr
deriving instance Show Coq_instr_id
deriving instance Show Coq_block
deriving instance Show Coq_definition
deriving instance Show Coq_toplevel_entity
deriving instance Show Coq_thread_local_storage
deriving instance Show Coq_global
deriving instance Show Coq_metadata
deriving instance Show Coq_modul

runG :: G () -> [Coq_block]
runG g = combine $ connect (execWriter (execStateT g 0))
  where
    final_term = error "Unterminated last block"
    connect [mkBlock]          = [mkBlock final_term]
    connect (mkBlock:mkBlocks) = mkBlock (TERM_Br_1 tident) : blocks'
      where blocks' = connect mkBlocks
            tident = (TYPE_Label, ID_Local (blk_id (head blocks')))
    combine ( (Coq_mk_block i1 bs1 (TERM_Br_1 (TYPE_Label, ID_Local (Anon br))) _)
            : (Coq_mk_block (Anon i2) bs2 t v)
            : blocks ) | br == i2
            = combine (Coq_mk_block i1 (bs1 ++ bs2) t v : blocks)
    combine (b:bs) = b : combine bs
    combine [] = []

fresh :: G Int
fresh = do
    n <- get
    put (n+1)
    return n

freshAnon :: G Coq_local_id
freshAnon = Anon <$> fresh

emitTerm :: Coq_terminator -> G ()
emitTerm t = do
    blockId <- freshAnon
    tell [\_ -> Coq_mk_block blockId [] t (IVoid 0)]

emitInstr :: Coq_instr -> G Coq_ident
emitInstr instr = do
    instrId <- freshAnon
    emitNamedInstr instrId instr
    return (ID_Local instrId)

emitNamedInstr :: Coq_local_id -> Coq_instr -> G ()
emitNamedInstr instrId instr = do
    blockId <- freshAnon
    tell [\t -> Coq_mk_block blockId [(IId instrId, instr)] t (IVoid 0)]

namedBlock :: Coq_local_id -> G ()
namedBlock blockId = do
    tell [\t -> Coq_mk_block blockId [] t (IVoid 0)]

namedBr1Block :: Coq_local_id -> Coq_local_id -> G ()
namedBr1Block blockId toBlockId = do
    tell [\_ -> Coq_mk_block blockId [] (TERM_Br_1 (TYPE_Label, ID_Local toBlockId)) (IVoid 0)]

namedPhiBlock :: Coq_typ -> Coq_block_id -> [(Coq_ident, Coq_block_id)] -> G Coq_ident
namedPhiBlock ty blockId pred = do
    tmpId <- freshAnon
    let phi = (IId tmpId, INSTR_Phi ty [ (i, SV (VALUE_Ident (ID_Local l))) | (i,l) <- pred ])
    tell [\t -> Coq_mk_block blockId [phi] t (IVoid 0)]
    return (ID_Local tmpId)

---

returnFromFunction :: Coq_ident -> G ()
returnFromFunction lid = emitTerm (TERM_Ret (hsTyP, ident lid))


collectMoreValBinders :: CoreExpr -> ([Id], CoreExpr)
collectMoreValBinders = go []
  where
    go ids (Lam b e) | isId b = go (b:ids) e
    go ids (Lam b e)          = go ids e
    go ids (Cast e _)         = go ids e
    go ids body               = (reverse ids, body)

genExpr :: GenEnv -> CoreExpr -> G Coq_ident
genExpr env (Cast e _) = genExpr env e

genExpr env (Case scrut b _ [(DEFAULT, _, body)]) = do
    scrut_eval <- genExpr env scrut
    emitNamedInstr (varRawId b) $ noop hsTyP (ident scrut_eval)
    genExpr env body

genExpr env (Case scrut b _ alts) = do
    scrut_eval <- genExpr env scrut
    emitNamedInstr (varRawId b) $ noop hsTyP (ident scrut_eval)

    emitNamedInstr scrut_cast_raw_id $ INSTR_Op (SV (OP_Conversion Bitcast hsTyP (ident scrut_eval) dataConTyP))
    t <- getTag scrut_cast_ident
    emitTerm $ tagSwitch t [ (tagOf ac, caseAltEntryRawId b (tagOf ac))
                           | (ac, _, _) <- alts ]

    mapM_ genAlt alts

    res <- namedPhiBlock hsTyP (caseAltJoinRawId b)
        [ (caseAltRetIdent b (tagOf ac), caseAltExitRawId b (tagOf ac))
        | (ac, _, _) <- alts ]
    return res
  where
    tagSwitch :: Coq_ident -> [(Maybe Int, Coq_local_id)] -> Coq_terminator
    tagSwitch tag ((_,l):xs) =
        TERM_Switch (tagTy,ident tag) (TYPE_Label, ID_Local l)
            [ ((tagTy, SV (VALUE_Integer n)), (TYPE_Label, ID_Local l))
            | (Just n, l) <- xs ]

    scrut_cast_raw_id = caseScrutCastedRawId b
    scrut_cast_ident = caseScrutCastedIdent b
    tagOf DEFAULT      = Nothing
    tagOf (DataAlt dc) = Just (dataConTag dc)
    genAlt (ac, pats, rhs) = do
        namedBlock (caseAltEntryRawId b (tagOf ac))
        forM_ (zip [0..] pats) $ \(n,pat) -> do
            patPtr <- emitInstr $ getElemPtr dataConTyP scrut_cast_ident [0,2,n]
            emitNamedInstr (varRawId pat) $ INSTR_Load False hsTyP (hsTyP, ident patPtr) Nothing

        tmpId <- genExpr env rhs
        emitNamedInstr (caseAltRetRawId b (tagOf ac)) $ noop hsTyP (ident tmpId)
        namedBr1Block (caseAltExitRawId b (tagOf ac)) (caseAltJoinRawId b)

genExpr env (Let binds body) = do
    let (allocs, fills) = unzip [ genLetBind env v e | (v,e) <- flattenBinds [binds] ]
    sequence_ allocs
    sequence_ fills
    genExpr env body
  where
    pairs = flattenBinds [binds]

genExpr env e
    | (f, args) <- collectArgs e
    , let args' = filter isValArg args
    , not (null args') = do
    let arity = length args'
    let thisFunClosTyP = TYPE_Pointer (mkFunClosureTy arity 0)
    let thisFunTyP = TYPE_Pointer (hsFunTy arity 0)

    evaledFun <- genExpr env f

    castedFun <- emitInstr $
        INSTR_Op (SV (OP_Conversion Bitcast hsTyP (ident evaledFun) thisFunClosTyP))
    codePtr <- emitInstr $ getElemPtr thisFunClosTyP castedFun [0,1]
    code <- emitInstr $ INSTR_Load False thisFunTyP (thisFunTyP, ident codePtr) Nothing

    closPtr <- emitInstr $ getElemPtr thisFunClosTyP castedFun [0,3]
    args_locals <- mapM (genArg env) args'
    emitInstr $ INSTR_Call (thisFunTyP, code) $
        (envTyP 0, ident closPtr) : [(hsTyP, ident a) | a <- args_locals ]
  where

{-
genExpr env e@(Var v) | Just dc <- isDataConId_maybe v, isUnboxedTupleCon dc =
    pprTrace "genExpr" (ppr e) $
    emitInstr $ noop hsTyP (SV (VALUE_Null))
-}

genExpr env (Var v) | isGlobalId v || v `elemVarSet` env =  do
    -- Should not be necessary once I find out how to cast the global variable to hsTyP
    castedPtr <- emitInstr $
        INSTR_Op (SV (OP_Conversion Bitcast (mkFunClosureTy (idArity v) 0) (ident (varIdent env v)) hsTyP))
    codePtr <- emitInstr $ getElemPtr hsTyP castedPtr [0,0]
    code <- emitInstr $ INSTR_Load False enterFunTyP (enterFunTyP, ident codePtr) Nothing
    emitInstr $ INSTR_Call (enterFunTyP, code) [(hsTyP, ident castedPtr)]

genExpr env (Var v) = do
    codePtr <- emitInstr $ getElemPtr hsTyP (varIdent env v) [0,0]
    code <- emitInstr $ INSTR_Load False enterFunTyP (enterFunTyP, ident codePtr) Nothing
    emitInstr $ INSTR_Call (enterFunTyP, code) [(hsTyP, ident (varIdent env v))]

genExpr env e =
    pprTrace "genExpr" (ppr e) $
    emitInstr $ noop hsTyP (SV (VALUE_Null))

genArg :: GenEnv -> CoreArg -> G Coq_ident
genArg env (Cast e _) = genArg env e
genArg env (App e a) | isTyCoArg a = genArg env e
{- Should not be needed
genArg (Var v) | Just dc <- isDataConWorkId_maybe v = do
    allocateDataCon dc []
-}
genArg env (Var v) | isGlobalId v || v `elemVarSet` env =  do
    -- Should not be necessary once I find out how to cast the global variable to hsTyP
    emitInstr $
        INSTR_Op (SV (OP_Conversion Bitcast (mkFunClosureTy (idArity v) 0) (ident (varIdent env v)) hsTyP))
genArg env (Var v) = do
    return $ varIdent env v
genArg env e = pprPanic "genArg" (ppr e)

genLetBind :: GenEnv -> Var -> CoreExpr -> (G (), G ())
genLetBind env v e
    | (Var f, args) <- collectArgs e
    , Just dc <- isDataConId_maybe f
    = let (alloc, fill) = allocateDataCon (varRawId v) dc
          fill' = do
            arg_locals <- mapM (genArg env) (filter isValArg args)
            fill arg_locals
      in (alloc, fill')

genLetBind env v e = (alloc, fill)
  where
    alloc = do
        thunkRawPtr <- genMalloc thisThunkTyP
        emitNamedInstr (varRawId v) $
            INSTR_Op (SV (OP_Conversion Bitcast mallocRetTyP (ident thunkRawPtr) hsTyP))

    fill = do
        castedPtr <- emitInstr $
            INSTR_Op (SV (OP_Conversion Bitcast hsTyP (ident (varIdent env v)) thisThunkTyP))
        -- TODO: Pointer to code function here
        forM_ (zip [0..] fvs) $ \(n,fv) -> do
            p <- emitInstr $ getElemPtr thisThunkTyP castedPtr [0,1,n]
            emitInstr $ INSTR_Store False (hsTyP, ident p) (hsTyP, ident (varIdent env v)) Nothing

    fvs = exprsFreeVarsList [e]
    thisThunkTyP = TYPE_Pointer $ mkThunkTy (length fvs)


getTag :: Coq_ident -> G Coq_ident
getTag scrut_cast = do
    tagPtr <- emitInstr $ getElemPtr dataConTyP scrut_cast [0,1]
    loaded <- emitInstr $ INSTR_Load False tagTy (tagTyP, ident tagPtr) Nothing
    return loaded


getElemPtr :: Coq_typ -> Coq_ident -> [Int] -> Coq_instr
getElemPtr t v path
    = INSTR_Op (SV (OP_GetElementPtr t (t, ident v) [(TYPE_I 32, SV (VALUE_Integer n))| n <- path]))

ident id = SV (VALUE_Ident id)

noop ty val = INSTR_Op (SV (OP_Conversion Bitcast ty val ty))

dummyBody :: [Coq_block]
dummyBody = [ Coq_mk_block (Anon 0)
                [] (TERM_Ret (hsTyP, SV VALUE_Null))
                (IVoid 1)
            ]

mkHsFunDefinition :: Coq_linkage -> Coq_raw_id -> [Coq_raw_id] -> [Coq_block] -> Coq_definition
mkHsFunDefinition linkage n param_names blocks = Coq_mk_definition
    (mkHsFunDeclaration linkage n param_names)
    (Name "clos" :  param_names)
    blocks

mkHsFunDeclaration :: Coq_linkage -> Coq_raw_id -> [Coq_raw_id] -> Coq_declaration
mkHsFunDeclaration linkage n param_names = Coq_mk_declaration
    n
    (hsFunTy (length param_names) 0)
    ([],([] : map (const []) param_names))
    (Just linkage)
    Nothing
    Nothing
    Nothing
    []
    Nothing
    Nothing
    Nothing

mkEnterFunDefinition :: Coq_linkage -> String -> [Coq_block] -> Coq_definition
mkEnterFunDefinition linkage n blocks = Coq_mk_definition
    (mkEnterFunDeclaration linkage n)
    [Name "clos"]
    blocks

mkEnterFunDeclaration :: Coq_linkage -> String -> Coq_declaration
mkEnterFunDeclaration linkage n = Coq_mk_declaration
    (Name n)
    enterFunTy
    ([],[[]])
    (Just linkage)
    Nothing
    Nothing
    Nothing
    []
    Nothing
    Nothing
    Nothing


codeNameStr :: Name -> String
codeNameStr n | isExternalName n =
    intercalate "_" $ map zEncodeString
        [ moduleNameString (moduleName (nameModule n))
        , occNameString (nameOccName n)
        ]
codeNameStr n  =
    intercalate "_" $ map zEncodeString
    [ occNameString (nameOccName n)
    , show (nameUnique n)
    ]

funIdent :: GenEnv -> Id -> Coq_ident
funIdent env v
    | isGlobalId v || v `elemVarSet` env
    = ID_Global (funRawId v)
    | otherwise
    = ID_Local (funRawId v)
funRawId :: Id ->  Coq_raw_id
funRawId v = Name (codeNameStr (getName v) ++ "_fun")

varIdent :: GenEnv -> Id -> Coq_ident
varIdent env v
    | isGlobalId v || v `elemVarSet` env
    = ID_Global (varRawId v)
    | otherwise
    = ID_Local (varRawId v)
varRawId :: Id ->  Coq_raw_id
varRawId v = Name (codeNameStr (getName v))


caseScrutCastedIdent :: Var -> Coq_ident
caseScrutCastedIdent n = ID_Local (caseScrutCastedRawId n)

caseScrutCastedRawId :: Var -> Coq_raw_id
caseScrutCastedRawId n = Name (codeNameStr (getName n) ++ "_casted")

caseAltEntryIdent :: Var -> Maybe Int -> Coq_ident
caseAltEntryIdent v mbi = ID_Local (caseAltEntryRawId v mbi)

caseAltEntryRawId :: Var -> Maybe Int -> Coq_raw_id
caseAltEntryRawId n Nothing  = Name (codeNameStr (getName n) ++ "_br_def")
caseAltEntryRawId n (Just i) = Name (codeNameStr (getName n) ++ "_br_" ++ show i)

caseAltRetIdent :: Var -> Maybe Int -> Coq_ident
caseAltRetIdent v mbi = ID_Local (caseAltRetRawId v mbi)

caseAltRetRawId :: Var -> Maybe Int -> Coq_raw_id
caseAltRetRawId n Nothing  = Name (codeNameStr (getName n) ++ "_br_ret")
caseAltRetRawId n (Just i) = Name (codeNameStr (getName n) ++ "_br_ret_" ++ show i)

caseAltExitIdent :: Var -> Maybe Int -> Coq_ident
caseAltExitIdent v mbi = ID_Local (caseAltExitRawId v mbi)

caseAltExitRawId :: Var -> Maybe Int -> Coq_raw_id
caseAltExitRawId n Nothing  = Name (codeNameStr (getName n) ++ "_br_ex")
caseAltExitRawId n (Just i) = Name (codeNameStr (getName n) ++ "_br_ex_" ++ show i)

caseAltJoin :: Var -> Coq_ident
caseAltJoin n = ID_Local (Name (codeNameStr (getName n) ++ "_br_join"))

caseAltJoinIdent :: Var -> Coq_ident
caseAltJoinIdent v = ID_Local (caseAltJoinRawId v)

caseAltJoinRawId :: Var -> Coq_raw_id
caseAltJoinRawId n = Name (codeNameStr (getName n) ++ "_br_join")





mkCoqModul :: String -> [Coq_global] -> [Coq_type_decl] -> [Coq_declaration] -> [Coq_definition] -> Coq_modul
mkCoqModul name globals tydecls declarations definitions
    = Coq_mk_modul name
        (TLE_Target "x86_64-pc-linux")
        (TLE_Source_filename "no data layout here")
        (map ("",) globals)
        (map ("",) tydecls)
        (map ("",) declarations)
        (map ("",) definitions)

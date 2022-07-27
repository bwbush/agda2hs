module Agda2Hs.Compile where

import Control.Arrow ( (>>>), (***), (&&&), first, second )
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader

import Data.Generics ( mkT, everywhere, listify, extT, everything, mkQ, Data )
import Data.List
import Data.List.NonEmpty ( NonEmpty(..) )
import Data.Maybe
import Data.Map ( Map )
import qualified Data.Text as Text
import qualified Data.Map as Map
import qualified Data.HashMap.Strict as HMap

import qualified Language.Haskell.Exts.Syntax as Hs
import qualified Language.Haskell.Exts.Build as Hs
import qualified Language.Haskell.Exts.Parser as Hs
import qualified Language.Haskell.Exts.Extension as Hs

import Agda.Compiler.Backend
import Agda.Compiler.Common
import Agda.Interaction.BasicOps

import Agda.Syntax.Common hiding ( Ranged )
import qualified Agda.Syntax.Concrete.Name as C
import Agda.Syntax.Literal
import Agda.Syntax.Internal
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import Agda.Syntax.Scope.Monad hiding ( withCurrentModule )

import Agda.TypeChecking.CheckInternal ( infer )
import Agda.TypeChecking.Constraints ( noConstraints )
import Agda.TypeChecking.Conversion ( equalTerm )
import Agda.TypeChecking.InstanceArguments ( findInstance )
import Agda.TypeChecking.Level ( isLevelType )
import Agda.TypeChecking.MetaVars ( newInstanceMeta )
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce ( instantiate, reduce )
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Records
import Agda.TypeChecking.Sort ( ifIsSort )

import Agda.Utils.Lens
import Agda.Utils.Pretty ( prettyShow )
import qualified Agda.Utils.Pretty as P
import Agda.Utils.List
import Agda.Utils.Impossible
import Agda.Utils.Monad
import Agda.Utils.Size
import Agda.Utils.Functor

import Agda2Hs.AgdaUtils
import Agda2Hs.Compile.ClassInstance
import Agda2Hs.Compile.Data
import Agda2Hs.Compile.Function
import Agda2Hs.Compile.Name
import Agda2Hs.Compile.Postulate
import Agda2Hs.Compile.Record
import Agda2Hs.Compile.Type
import Agda2Hs.Compile.Types
import Agda2Hs.Compile.Utils
import Agda2Hs.HsUtils
import Agda2Hs.Pragma

initCompileEnv :: CompileEnv
initCompileEnv = CompileEnv { minRecordName = Nothing }

runC :: C a -> TCM a
runC m = runReaderT m initCompileEnv

-- Main compile function
------------------------

compile :: Options -> ModuleEnv -> IsMain -> Definition -> TCM CompiledDef
compile _ m _ def = withCurrentModule m $ runC $ processPragma (defName def) >>= \ p -> do
  reportSDoc "agda2hs.compile" 5 $ text "Compiling definition: " <+> prettyTCM (defName def)
  case (p , defInstance def , theDef def) of
    (NoPragma           , _      , _         ) -> return []
    (ExistingClassPragma, _      , _         ) -> return [] -- No code generation, but affects how projections are compiled
    (ClassPragma ms     , _      , Record{}  ) -> tag . single <$> compileRecord (ToClass ms) def
    (DerivingPragma ds  , _      , Datatype{}) -> tag <$> compileData ds def
    (DefaultPragma      , _      , Datatype{}) -> tag <$> compileData [] def
    (DefaultPragma      , Just _ , _         ) -> tag . single <$> compileInstance def
    (DefaultPragma      , _      , Axiom{}   ) -> tag <$> compilePostulate def
    (DefaultPragma      , _      , Function{}) -> tag <$> compileFun def
    (DefaultPragma      , _      , Record{}  ) -> tag . single <$> compileRecord ToRecord def
    _                                         -> return []
  where tag code = [(nameBindingSite $ qnameName $ defName def, code)]
        single x = [x]

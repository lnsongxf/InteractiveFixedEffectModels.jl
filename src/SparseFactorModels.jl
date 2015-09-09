VERSION >= v"0.4.0-dev+6521" &&  __precompile__(true)

module SparseFactorModels

##############################################################################
##
## Dependencies
##
##############################################################################

using Reexport
@reexport using FixedEffectModels
import FixedEffectModels: title, top
using Compat
using Optim
import StatsBase: coef, nobs, coeftable, vcov, predict, residuals, var, RegressionModel, model_response, stderr, confint, fit, CoefTable,  df_residual
import DataArrays: RefArray, PooledDataVector, DataVector, PooledDataArray, DataArray
import DataFrames: DataFrame, AbstractDataFrame, ModelMatrix, ModelFrame, Terms, coefnames, Formula, complete_cases, names!
import Distances: sqeuclidean

##############################################################################
##
## Exported methods and types 
##
##############################################################################

export SparseFactorModel,
SparseFactorResult

##############################################################################
##
## Load files
##
##############################################################################

include("utils/models.jl")
include("utils/chebyshev.jl")

include("types.jl")

include("algorithms/ar.jl")
include("algorithms/svd.jl")
include("algorithms/optim.jl")

include("fit.jl")

end
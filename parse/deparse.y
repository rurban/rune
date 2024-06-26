//  Copyright 2021 Google LLC.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

%{

// Substitute the variable and function names.
#define yyparse         deparse
#define yylex           delex
#define yyerror         deerror
#define yydebug         dedebug
#define yynerrs         denerrs
#define yylval          delval
#define yychar          dechar

#include "parse.h"

#include <stdlib.h>

static deBlock deSavedBlock;
static deStatement deLastStatement;
static uint32 deSkippedCodeNestedDepth;
static bool deInUnitTest;

// Provide yyerror function capability.
void deerror(char *message, ...) {
  char *buff;
  va_list ap;
  va_start(ap, message);
  buff = utVsprintf(message, ap);
  va_end(ap);
  uint32 lineNum = deLineNum;
  if (deCurrentLine != deLineNull) {
    lineNum = deLineGetLineNum(deCurrentLine);
  }
  if (!deInvertReturnCode) {
    utError("%s:%d: token \"%s\": %s", deCurrentFileName, lineNum, detext, buff);
  }
  printf("%s:%d: token \"%s\": %s\n", deCurrentFileName, lineNum, detext, buff);
  printf("Exiting due to error...\n");
  deGenerateDummyLLFileAndExit();
}

// Create a new block statement and set the sub-block current.
static deStatement createBlockStatement(deStatementType type, deLine line) {
  deStatement statement = deStatementCreate(deCurrentBlock, type, line);
  deBlock subBlock = deBlockCreate(deCurrentFilepath, DE_BLOCK_STATEMENT, line);
  deStatementInsertSubBlock(statement, subBlock);
  deBlockSetLine(subBlock, line);
  deCurrentBlock = subBlock;
  return statement;
}

// Assign the expression to the current block's statement, and pop
// to the next higher block.
static void finishBlockStatement(deExpression expression) {
  deStatement statement = deBlockGetOwningStatement(deCurrentBlock);
  if (expression != deExpressionNull) {
    deStatementInsertExpression(statement, expression);
  }
  deCurrentBlock = deStatementGetBlock(statement);
}

// Move the statements after deLastStatement to the start of the block.  This is used to prepend
// statements, rather than append.
static void moveNewStatementsToBlockStart(void) {
  if (deLastStatement == deStatementNull) {
    return;
  }
  deStatement nextStatement = deStatementGetNextBlockStatement(deLastStatement);
  if (nextStatement == deStatementNull) {
    return;
  }
  deBlock block = deStatementGetBlock(deLastStatement);
  // Break the connection from deLastStatement to nextStatement.
  deStatementSetNextBlockStatement(deLastStatement, deStatementNull);
  deStatementSetPrevBlockStatement(nextStatement, deStatementNull);
  // Connect the last statement to the first.
  deStatement firstStatement = deBlockGetFirstStatement(block);
  deStatement lastStatement = deBlockGetLastStatement(block);
  deStatementSetNextBlockStatement(lastStatement, firstStatement);
  deStatementSetPrevBlockStatement(firstStatement, lastStatement);
  // Set first and last pointers.
  deBlockSetFirstStatement(block, nextStatement);
  deBlockSetLastStatement(block, deLastStatement);
}

// Set the function linkage to extern C or extern RPC.
static void setFunctionExtern(deFunction function, deString langName) {
  if (!strcmp(deStringGetCstr(langName), "C")) {
    deFunctionSetLinkage(function, DE_LINK_EXTERN_C);
    deFunctionSetExtern(function, true);
  } else if (!strcmp(deStringGetCstr(langName), "RPC")) {
    deFunctionSetLinkage(function, DE_LINK_EXTERN_RPC);
    deFunctionSetExtern(function, true);
  } else {
    deError(deFunctionGetLine(function), "Only extern \"C\" linkage currently supported");
  }
}

// Check that deCurrentBlock is a module or package block.
static void checkTopBlock(char *statementType) {
  if (deSkippedCodeNestedDepth != 0) {
    return;
  }
  if (deBlockGetType(deCurrentBlock) == DE_BLOCK_FUNCTION) {
    deFunction function = deBlockGetOwningFunction(deCurrentBlock);
    deFunctionType type = deFunctionGetType(function);
    if (type == DE_FUNC_PACKAGE || type == DE_FUNC_MODULE || type == DE_FUNC_UNITTEST) {
      return;
    }
  }
  deerror("i%s statements must be at the top level", statementType);
}

// Check that the operator has 1 or 2 parameters, and set its name.  We have to
// wait until after parsing parameters to set the name, since we prepend
// "binary" or "unary".
void checkOperatorFunction(deFunction function) {
  uint32 numParams = deBlockCountParameterVariables(deFunctionGetSubBlock(function));
  if (numParams == 0 || numParams > 2) {
    deError(deFunctionGetLine(function), "Operators must have 1 or 2 parameters");
  }
  utSym name = deGetOperatorSym(deFunctionGetOpType(function), numParams == 1);
  deSetOperatorFunctionName(function, name);
}

// Move import and use statements in a unit test to |destBlock|.
static void moveImportsToBlock(deBlock subBlock, deBlock destBlock) {
  deStatement statement;
  deSafeForeachBlockStatement(subBlock, statement) {
    if (deStatementIsImport(statement)) {
      deBlockRemoveStatement(subBlock, statement);
      deBlockAppendStatement(destBlock, statement);
    }
  } deEndSafeBlockStatement;
}

%}

%union {
  utSym symVal;
  deString stringVal;
  deBigint bigintVal;
  bool boolVal;
  deExpression exprVal;
  uint16 uint16Val;
  deLine lineVal;
  deExpressionType exprTypeVal;
  deFloat floatVal;
};

%token <symVal> IDENT
%token <stringVal> STRING
%token <bigintVal> INTEGER
%token <uint16Val> RANDUINT INTTYPE UINTTYPE
%token <boolVal> BOOL
%token <floatVal> FLOAT

%type <boolVal> optVar
%type <exprTypeVal> assignmentOp
%type <exprTypeVal> operator
%type <exprVal> accessExpression
%type <exprVal> writableExpression
%type <exprVal> callExpression
%type <exprVal> addExpression
%type <exprVal> andExpression
%type <exprVal> assignmentExpression
%type <exprVal> bitandExpression
%type <exprVal> bitorExpression
%type <exprVal> bitxorExpression
%type <exprVal> callParameter
%type <exprVal> callParameterList
%type <exprVal> dotDotDotExpression
%type <exprVal> exponentiateExpression
%type <exprVal> expression
%type <exprVal> expressionList
%type <exprVal> raiseExpressionList
%type <exprVal> inExpression
%type <exprVal> modExpression
%type <exprVal> mulExpression
%type <exprVal> oneOrMoreExpressions
%type <exprVal> oneOrMoreCallParameters
%type <exprVal> oneOrMoreTypeExpressions
%type <exprVal> oneOrMorePathExpressions
%type <exprVal> optCascade
%type <uint16Val> optWidth
%type <exprVal> optCallParameterList
%type <exprVal> optFuncTypeExpression
%type <exprVal> optInitializer
%type <exprVal> optLabel
%type <exprVal> optTypeExpression
%type <exprVal> typeExpression
%type <exprVal> typePathExpression
%type <exprVal> typeRangeExpression
%type <exprVal> compoundTypeExpression
%type <exprVal> typeRangeExpressionList
%type <exprVal> basicTypeExpression
%type <exprVal> orExpression
%type <exprVal> pathExpression
%type <exprVal> pathExpressionWithAlias
%type <exprVal> prefixExpression
%type <exprVal> relationExpression
%type <exprVal> selectExpression
%type <exprVal> shiftExpression
%type <exprVal> switchCaseHeaders
%type <exprVal> typeswitchCaseHeaders
%type <exprVal> exceptCaseHeaders
%type <exprVal> tokenExpression
%type <exprVal> returnsTokenExpression
%type <exprVal> tupleExpression
%type <exprVal> twoOrMoreExpressions
%type <exprVal> typeLiteral
%type <exprVal> xorExpression

%token <lineVal> KWADDEQUALS
%token <lineVal> KWADDTRUNC
%token <lineVal> KWADDTRUNCEQUALS
%token <lineVal> KWAND
%token <lineVal> KWANDEQUALS
%token <lineVal> KWAPPENDCODE
%token <lineVal> KWARRAYOF
%token <lineVal> KWARROW
%token <lineVal> KWIMPLIES
%token <lineVal> KWAS
%token <lineVal> KWASSERT
%token <lineVal> KWBITANDEQUALS
%token <lineVal> KWBITOREQUALS
%token <lineVal> KWBITXOREQUALS
%token <lineVal> KWBOOL
%token <lineVal> KWCASCADE
%token <lineVal> KWCASTTRUNC
%token <lineVal> KWCLASS
%token <lineVal> KWDEBUG
%token <lineVal> KWDEFAULT
%token <lineVal> KWDIVEQUALS
%token <lineVal> KWDO
%token <lineVal> KWDOTDOTDOT
%token <lineVal> KWELSE
%token <lineVal> KWENUM
%token <lineVal> KWEQUAL
%token <lineVal> KWEXP
%token <lineVal> KWEXPEQUALS
%token <lineVal> KWEXPORT
%token <lineVal> KWEXPORTLIB
%token <lineVal> KWRPC
%token <lineVal> KWEXTERN
%token <lineVal> KWF32
%token <lineVal> KWF64
%token <lineVal> KWFINAL
%token <lineVal> KWFOR
%token <lineVal> KWFUNC
%token <lineVal> KWGE
%token <lineVal> KWTRANSFORM
%token <lineVal> KWTRANSFORMER
%token <lineVal> KWIF
%token <lineVal> KWIMPORT
%token <lineVal> KWIMPORTLIB
%token <lineVal> KWIMPORTRPC
%token <lineVal> KWIN
%token <lineVal> KWISNULL
%token <lineVal> KWITERATOR
%token <lineVal> KWLE
%token <lineVal> KWMOD
%token <lineVal> KWMODEQUALS
%token <lineVal> KWMULEQUALS
%token <lineVal> KWMULTRUNC
%token <lineVal> KWMULTRUNCEQUALS
%token <lineVal> KWNOTEQUAL
%token <lineVal> KWNONE
%token <lineVal> KWNULL
%token <lineVal> KWOPERATOR
%token <lineVal> KWOR
%token <lineVal> KWOREQUALS
%token <lineVal> KWPREPENDCODE
%token <lineVal> KWPRINT
%token <lineVal> KWPRINTLN
%token <lineVal> KWREF
%token <lineVal> KWRELATION
%token <lineVal> KWRETURN
%token <lineVal> KWREVEAL
%token <lineVal> KWROTL
%token <lineVal> KWROTLEQUALS
%token <lineVal> KWROTR
%token <lineVal> KWROTREQUALS
%token <lineVal> KWSECRET
%token <lineVal> KWSHL
%token <lineVal> KWSHLEQUALS
%token <lineVal> KWSHR
%token <lineVal> KWSHREQUALS
%token <lineVal> KWSIGNED
%token <lineVal> KWSTRING
%token <lineVal> KWSTRUCT
%token <lineVal> KWSUBEQUALS
%token <lineVal> KWSUBTRUNC
%token <lineVal> KWSUBTRUNCEQUALS
%token <lineVal> KWSWITCH
%token <lineVal> KWTRY
%token <lineVal> KWEXCEPT
%token <lineVal> KWRAISE
%token <lineVal> KWRAISES
%token <lineVal> KWPANIC
%token <lineVal> KWTYPEOF
%token <lineVal> KWTYPESWITCH
%token <lineVal> KWUNITTEST
%token <lineVal> KWUNREF
%token <lineVal> KWUNSIGNED
%token <lineVal> KWUSE
%token <lineVal> KWVAR
%token <lineVal> KWWHILE
%token <lineVal> KWWIDTHOF
%token <lineVal> KWXOR
%token <lineVal> KWXOREQUALS
%token <lineVal> KWYIELD

%token <lineVal> '!'
%token <lineVal> '%'
%token <lineVal> '&'
%token <lineVal> '('
%token <lineVal> ')'
%token <lineVal> '*'
%token <lineVal> '+'
%token <lineVal> ','
%token <lineVal> '-'
%token <lineVal> '.'
%token <lineVal> '/'
%token <lineVal> ':'
%token <lineVal> ';'
%token <lineVal> '<'
%token <lineVal> '='
%token <lineVal> '>'
%token <lineVal> '?'
%token <lineVal> '^'
%token <lineVal> '['
%token <lineVal> ']'
%token <lineVal> '{'
%token <lineVal> '|'
%token <lineVal> '}'
%token <lineVal> '~'

%%

goal: initialize optNewlines runeFile

initialize: // Empty
{
  deSavedBlock = deBlockNull;
  deInTransformer = false;
  deInIterator = false;
  deSkippedCodeNestedDepth = 0;
  deInUnitTest = false;
}

runeFile: statements

statements: // Empty
| statements statement

statement: appendCode
| assertStatement
| assignmentStatement
| callStatement
| class
| debugStatement
| enum
| externFunction
| finalFunction
| foreachStatement
| forStatement
| function
| transformStatement
| transformer
| ifStatement
| import
| prependCode
| printlnStatement
| printStatement
| refStatement
| relationStatement
| returnStatement
| struct
| switchStatement
| typeswitchStatement
| tryExceptStatements
| exceptStatement
| raiseStatement
| panicStatement
| unitTest
| unrefStatement
| whileStatement
| yield


import: KWIMPORT pathExpressionWithAlias newlines
{
  // Could also be importing a package.  This gets resolved when we find a file vs a directory.
  checkTopBlock("Import");
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_IMPORT, $1);
  deStatementSetExpression(statement, $2);
}
| KWIMPORTLIB pathExpressionWithAlias newlines
{
  checkTopBlock("Importlib");
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_IMPORTLIB, $1);
  deStatementSetExpression(statement, $2);
}
| KWIMPORTRPC pathExpressionWithAlias newlines
{
  checkTopBlock("Importrpc");
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_IMPORTRPC, $1);
  deStatementSetExpression(statement, $2);
}
| KWUSE IDENT newlines
{
  checkTopBlock("Use");
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_USE, $1);
  deStatementSetExpression(statement, deIdentExpressionCreate($2, $1));
}

class: classHeader '(' oneOrMoreParameters ')' optRaises block
{
  deCurrentBlock = deBlockGetOwningBlock(deCurrentBlock);
}
| exportClassHeader '(' oneOrMoreParameters ')' optRaises block
{
  deFunction constructor = deBlockGetOwningFunction(deCurrentBlock);
  deCreateFullySpecifiedSignature(constructor);
  deCurrentBlock = deBlockGetOwningBlock(deCurrentBlock);
}

classHeader: KWCLASS IDENT optWidth
{
  deFunction constructor = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_CONSTRUCTOR, $2, DE_LINK_MODULE, $1);
  deFunctionSetInUnitTest(constructor, deInUnitTest);
  deTemplateCreate(constructor, $3, $1);
  deCurrentBlock = deFunctionGetSubBlock(constructor);
}

optWidth:  // Empty
{
  $$ = 32;  // Default to 32 bit reference width by default.
}
| ':' UINTTYPE
{
  if ($2 > 64) {
    deError($1, "Class reference width cannot be > 64 bits");
  }
  $$ = $2;
}

exportClassHeader: KWEXPORT KWCLASS IDENT optWidth  // Means the constructor is in package API.
{
  deFunction constructor = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_CONSTRUCTOR, $3, DE_LINK_PACKAGE, $1);
  deFunctionSetInUnitTest(constructor, deInUnitTest);
  deTemplateCreate(constructor, $4, $1);
  deCurrentBlock = deFunctionGetSubBlock(constructor);
}
| KWEXPORTLIB KWCLASS IDENT optWidth  // Means the constructor is a libcall.
{
  deFunction constructor = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_CONSTRUCTOR, $3, DE_LINK_LIBCALL, $1);
  deFunctionSetInUnitTest(constructor, deInUnitTest);
  deTemplateCreate(constructor, $4, $1);
  deCurrentBlock = deFunctionGetSubBlock(constructor);
}
| KWRPC KWCLASS IDENT optWidth  // Means the constructor is an RPC call.
{
  deFunction constructor = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_CONSTRUCTOR, $3, DE_LINK_RPC, $1);
  deFunctionSetInUnitTest(constructor, deInUnitTest);
  deTemplateCreate(constructor, $4, $1);
  deCurrentBlock = deFunctionGetSubBlock(constructor);
}

struct: structHeader '{' newlines structMembers '}' newlines
{
  deCurrentBlock = deBlockGetOwningBlock(deCurrentBlock);
}
| exportStructHeader block
{
  deCurrentBlock = deBlockGetOwningBlock(deCurrentBlock);
}

structHeader: KWSTRUCT IDENT
{
  deFunction theStruct = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_STRUCT, $2, DE_LINK_MODULE, $1);
  deFunctionSetInUnitTest(theStruct, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(theStruct);
}

structMembers:  // Empty
| structMembers structMember newlines

structMember: IDENT optTypeExpression optInitializer
{
  deVariable parameter = deVariableCreate(deCurrentBlock, DE_VAR_PARAMETER,
      false, $1, $3, false, deCurrentLine);
  if ($2 != deExpressionNull) {
    deVariableInsertTypeExpression(parameter, $2);
  }
}

optInitializer:  // Empty
{
  $$ = deExpressionNull;
}
| '=' expression
{
  $$ = $2;
}

exportStructHeader: KWEXPORT KWSTRUCT IDENT  // Means the constructor is in package API.
{
  deFunction theStruct = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_STRUCT, $3, DE_LINK_PACKAGE, $1);
  deFunctionSetInUnitTest(theStruct, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(theStruct);
}
| KWEXPORTLIB KWSTRUCT IDENT  // Means the struct can be passed to/freom a libcall.
{
  deFunction theStruct = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_STRUCT, $3, DE_LINK_LIBCALL, $1);
  deFunctionSetInUnitTest(theStruct, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(theStruct);
}

appendCode: appendCodeHeader block
{
  if (deInTransformer) {
    finishBlockStatement(deExpressionNull);
    deGenerating = false;
  } else {
    deCurrentBlock = deSavedBlock;
    deSavedBlock = deBlockNull;
  }
}

appendCodeHeader: KWAPPENDCODE pathExpression
{
  if (deInTransformer) {
    if (deGenerating) {
      deError($1, "Cannot appendcode inside another appendcode statement");
    }
    deGenerating = true;
    deStatement statement = createBlockStatement(DE_STATEMENT_APPENDCODE, $1);
    deStatementSetExpression(statement, $2);
  } else {
    if (deSavedBlock != deBlockNull) {
      deError( $1, "Cannot append code inside another append/prepend statement");
    }
    deBlock scopeBlock = deBlockGetScopeBlock(deCurrentBlock);
    deIdent ident = deFindIdentFromPath(scopeBlock, $2);
    if (ident == deIdentNull) {
      deError($1, "Path does not exist");
    } else if (deIdentGetType(ident) != DE_IDENT_FUNCTION) {
      deError($1, "Identifier is not a class or function", deIdentGetName(ident));
    }
    deSavedBlock = deCurrentBlock;
    deCurrentBlock = deIdentGetSubBlock(ident);
  }
}
| KWAPPENDCODE  // Append to module block.
{
  if (deInTransformer) {
    if (deGenerating) {
      deError($1, "Cannot appendcode inside another appendcode statement");
    }
    deGenerating = true;
    createBlockStatement(DE_STATEMENT_APPENDCODE, $1);
  } else {
    if (deSavedBlock != deBlockNull) {
      deError( $1, "Cannot append code inside another append/prepend statement");
    }
    deSavedBlock = deCurrentBlock;
    deCurrentBlock = deFilepathGetModuleBlock(deBlockGetFilepath(deCurrentBlock));
  }
}

prependCode: prependCodeHeader block
{
  moveNewStatementsToBlockStart();
  if (deInTransformer) {
    finishBlockStatement(deExpressionNull);
    deGenerating = false;
  } else {
    deCurrentBlock = deSavedBlock;
    deSavedBlock = deBlockNull;
  }
}

prependCodeHeader: KWPREPENDCODE pathExpression
{
  if (deInTransformer) {
    if (deGenerating) {
      deError($1, "Cannot prependcode inside another prependcode statement");
    }
    deGenerating = true;
    deStatement statement = createBlockStatement(DE_STATEMENT_PREPENDCODE, $1);
    deStatementSetExpression(statement, $2);
  } else {
    if (deSavedBlock != deBlockNull) {
      deError( $1, "Cannot prepend code inside another append/prepend statement");
    }
    deBlock scopeBlock = deBlockGetScopeBlock(deCurrentBlock);
    deIdent ident = deFindIdentFromPath(scopeBlock, $2);
    if (ident == deIdentNull) {
      deError($1, "Path does not exist");
    } else if (deIdentGetType(ident) != DE_IDENT_FUNCTION) {
      deError($1, "Identifier %s already exists, but is not a class or function",
              deIdentGetName(ident));
    }
    deSavedBlock = deCurrentBlock;
    deCurrentBlock = deIdentGetSubBlock(ident);
    deLastStatement = deBlockGetLastStatement(deCurrentBlock);
  }
}
| KWPREPENDCODE
{
  if (deInTransformer) {
    if (deGenerating) {
      deError($1, "Cannot prependcode inside another prependcode statement");
    }
    deGenerating = true;
    createBlockStatement(DE_STATEMENT_PREPENDCODE, $1);
  } else {
    if (deSavedBlock != deBlockNull) {
      deError( $1, "Cannot prepend code inside another append/prepend statement");
    }
    deSavedBlock = deCurrentBlock;
    deCurrentBlock = deFilepathGetModuleBlock(deBlockGetFilepath(deCurrentBlock));
    deLastStatement = deBlockGetLastStatement(deCurrentBlock);
  }
}

block: '{' newlines statements '}' optNewlines

function: functionHeader '(' parameters ')' optFuncTypeExpression optRaises block
{
  deFunction function = deBlockGetOwningFunction(deCurrentBlock);
  if ($5 != deExpressionNull) {
    deFunctionInsertTypeExpression(function, $5);
  }
  if (deFunctionGetType(function) == DE_FUNC_OPERATOR) {
    checkOperatorFunction(function);
  }
  deCurrentBlock = deFunctionGetBlock(function);
  deInIterator = false;
}
| exportFunctionHeader '(' parameters ')' optFuncTypeExpression optRaises block
{
  deFunction function = deBlockGetOwningFunction(deCurrentBlock);
  if ($5 != deExpressionNull) {
    deFunctionInsertTypeExpression(function, $5);
  }
  deLinkage linkage = deFunctionGetLinkage(function);
  if (linkage == DE_LINK_LIBCALL || linkage == DE_LINK_RPC) {
    deCreateFullySpecifiedSignature(function);
  }
  deCurrentBlock = deFunctionGetBlock(function);
  deInIterator = false;
}
| rpcHeader '(' parameters ')' optFuncTypeExpression optRaises block
{
  deFunction function = deBlockGetOwningFunction(deCurrentBlock);
  if ($5 != deExpressionNull) {
    deFunctionInsertTypeExpression(function, $5);
  }
  deCurrentBlock = deFunctionGetBlock(function);
  deInIterator = false;
}

functionHeader: KWFUNC IDENT
{
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_PLAIN, $2, DE_LINK_MODULE, $1);
  deFunctionSetInUnitTest(function, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(function);
}
| KWITERATOR IDENT
{
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_ITERATOR, $2, DE_LINK_MODULE, $1);
  deFunctionSetInUnitTest(function, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(function);
  deInIterator = true;
}
| KWOPERATOR operator
{
  deFunction operator = deOperatorFunctionCreate(deCurrentBlock, $2, $1);
  deFunctionSetInUnitTest(operator, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(operator);
}

operator: '+'
{
  $$ = DE_EXPR_ADD;
}
| '-'
{
  $$ = DE_EXPR_SUB;
}
| '*'
{
  $$ = DE_EXPR_MUL;
}
| '/'
{
  $$ = DE_EXPR_DIV;
}
| '%'
{
  $$ = DE_EXPR_MOD;
}
| KWAND
{
  $$ = DE_EXPR_AND;
}
| KWOR
{
  $$ = DE_EXPR_OR;
}
| KWXOR
{
  $$ = DE_EXPR_XOR;
}
| '&'
{
  $$ = DE_EXPR_BITAND;
}
| '|'
{
  $$ = DE_EXPR_BITOR;
}
| '^'
{
  $$ = DE_EXPR_BITXOR;
}
| KWEXP
{
  $$ = DE_EXPR_EXP;
}
| KWSHL
{
  $$ = DE_EXPR_SHL;
}
| KWSHR
{
  $$ = DE_EXPR_SHR;
}
| KWROTL
{
  $$ = DE_EXPR_ROTL;
}
| KWROTR
{
  $$ = DE_EXPR_ROTR;
}
| KWADDTRUNC
{
  $$ = DE_EXPR_ADDTRUNC;
}
| KWSUBTRUNC
{
  $$ = DE_EXPR_SUBTRUNC;
}
| KWMULTRUNC
{
  $$ = DE_EXPR_MULTRUNC;
}
| '~'
{
  $$ = DE_EXPR_BITNOT;
}
| '<'
{
  $$ = DE_EXPR_LT;
}
| KWLE
{
  $$ = DE_EXPR_LE;
}
| '>'
{
  $$ = DE_EXPR_GT;
}
| KWGE
{
  $$ = DE_EXPR_GE;
}
| KWEQUAL
{
  $$ = DE_EXPR_EQUAL;
}
| KWNOTEQUAL
{
  $$ = DE_EXPR_NOTEQUAL;
}
| '!'
{
  $$ = DE_EXPR_NOT;
}
| '[' ']'
{
  $$ = DE_EXPR_INDEX;
}
| '<' '>'
{
  $$ = DE_EXPR_CAST;
}
| KWIN
{
  $$ = DE_EXPR_IN;
}

exportFunctionHeader: KWEXPORT KWFUNC IDENT
{
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_PLAIN, $3, DE_LINK_PACKAGE, $1);
  deFunctionSetInUnitTest(function, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(function);
}
| KWEXPORT KWITERATOR IDENT
{
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_ITERATOR, $3, DE_LINK_PACKAGE, $1);
  deFunctionSetInUnitTest(function, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(function);
}
| KWEXPORTLIB KWFUNC IDENT
{
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock, DE_FUNC_PLAIN, $3,
      DE_LINK_LIBCALL, $1);
  deFunctionSetInUnitTest(function, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(function);
}

parameters:
| oneOrMoreParameters

oneOrMoreParameters: parameter
| oneOrMoreParameters ',' optNewlines parameter

parameter: optVar IDENT optTypeExpression
{
  deVariable parameter = deVariableCreate(deCurrentBlock, DE_VAR_PARAMETER, $1, $2,
      deExpressionNull, deGenerating || deInIterator, deCurrentLine);
  if ($3 != deExpressionNull) {
    deVariableInsertTypeExpression(parameter, $3);
  }
}
| optVar '<' IDENT '>' optTypeExpression
{
  if (!deBlockIsConstructor(deCurrentBlock)) {
    deError($2, "Class signature '(' parameters ')' are only allowed in class declarations");
  }
  deVariable parameter = deVariableCreate(deCurrentBlock, DE_VAR_PARAMETER, $1, $3,
      deExpressionNull, false, $2);
  deVariableSetInTemplateSignature(parameter, true);
  deTemplate templ = deFunctionGetTemplate(deBlockGetOwningFunction(deCurrentBlock));
  deTemplateSetIsTemplate(templ, true);
  deTemplateSetNumTemplateParams(templ, deTemplateGetNumTemplateParams(templ) + 1);
  if ($5 != deExpressionNull) {
    deVariableInsertTypeExpression(parameter, $5);
  }
}
| initializedParameter

optVar: // Empty
{
  $$ = true;  // Parameters are const by default.
}
| KWVAR
{
  if (deBlockGetType(deCurrentBlock) == DE_BLOCK_FUNCTION &&
      deFunctionGetType(deBlockGetOwningFunction(deCurrentBlock)) == DE_FUNC_STRUCT) {
    deError($1, "Variable parameters are not allowed in struct declarations.");
  }
  $$ = false;
}

initializedParameter: optVar IDENT optTypeExpression '=' expression
{
  if (!$1) {
    deError($4, "Parameters passed by reference cannot have initializers");
  }
  deVariable parameter = deVariableCreate(deCurrentBlock, DE_VAR_PARAMETER, $1, $2, $5, false, $4);
  if ($3 != deExpressionNull) {
    deVariableInsertTypeExpression(parameter, $3);
  }
}

externFunction: KWEXTERN STRING functionHeader '(' parameters ')' optFuncTypeExpression newlines
{
  deFunction function = deBlockGetOwningFunction(deCurrentBlock);
  if ($7 != deExpressionNull) {
    deFunctionInsertTypeExpression(function, $7);
  }
  deCurrentBlock = deFunctionGetBlock(function);
  setFunctionExtern(function, $2);
  deStringFree($2);
}
| rpcHeader '(' parameters ')' optFuncTypeExpression newlines
{
  deFunction function = deBlockGetOwningFunction(deCurrentBlock);
  if ($5 != deExpressionNull) {
    deFunctionInsertTypeExpression(function, $5);
  }
  deCurrentBlock = deFunctionGetBlock(function);
  deString string = deMutableCStringCreate("RPC");
  setFunctionExtern(function, string);
  deStringFree(string);
}

rpcHeader: KWRPC IDENT
{
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock, DE_FUNC_PLAIN, $2,
      DE_LINK_RPC, $1);
  deFunctionSetInUnitTest(function, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(function);
}

ifStatement: ifPart elseIfParts optElsePart

ifPart: ifStatementHeader expression block
{
  finishBlockStatement($2);
}

ifStatementHeader: KWIF
{
  createBlockStatement(DE_STATEMENT_IF, $1);
}

elseIfParts: // Empty
| elseIfParts elseIfPart

elseIfPart: elseIfStatementHeader expression block
{
  finishBlockStatement($2);
}

elseIfStatementHeader: KWELSE KWIF
{
  createBlockStatement(DE_STATEMENT_ELSEIF, $1);
}

optElsePart: // Empty
| elsePart

elsePart: elseStatementHeader block
{
  finishBlockStatement(deExpressionNull);
}

elseStatementHeader: KWELSE
{
  createBlockStatement(DE_STATEMENT_ELSE, $1);
}

switchStatement: switchStatementHeader expression switchBlock
{
  finishBlockStatement($2);
}

typeswitchStatement: typeswitchStatementHeader expression typeswitchBlock
{
  finishBlockStatement($2);
}

switchStatementHeader: KWSWITCH
{
  createBlockStatement(DE_STATEMENT_SWITCH, $1);
}

typeswitchStatementHeader: KWTYPESWITCH
{
  createBlockStatement(DE_STATEMENT_TYPESWITCH, $1);
}

switchBlock: '{' newlines switchCases optDefaultCase '}' optNewlines

typeswitchBlock: '{' newlines typeswitchCases optDefaultCase '}' optNewlines

exceptBlock: '{' newlines exceptCases optDefaultCase '}' optNewlines

switchCases:  // Empty
| switchCases switchCase

typeswitchCases:  // Empty
| typeswitchCases typeswitchCase

exceptCases:  // Empty
| exceptCases exceptCase

switchCase: switchCaseHeaders KWIMPLIES block
{
  finishBlockStatement(deExpressionNull);
}
| switchCaseHeaders KWIMPLIES statement
{
  finishBlockStatement(deExpressionNull);
}

typeswitchCase: typeswitchCaseHeaders KWIMPLIES block
{
  finishBlockStatement(deExpressionNull);
}
| typeswitchCaseHeaders KWIMPLIES statement
{
  finishBlockStatement(deExpressionNull);
}

exceptCase: exceptCaseHeaders KWIMPLIES block
{
  finishBlockStatement(deExpressionNull);
}
| exceptCaseHeaders KWIMPLIES statement
{
  finishBlockStatement(deExpressionNull);
}

switchCaseHeaders: expression
{
  deLine line = deExpressionGetLine($1);
  deStatement statement = createBlockStatement(DE_STATEMENT_CASE, line);
  $$ = deExpressionCreate(DE_EXPR_LIST, deExpressionGetLine($1));
  deStatementInsertExpression(statement, $$);
  deExpressionAppendExpression($$, $1);
}
| switchCaseHeaders ',' optNewlines expression
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

typeswitchCaseHeaders: typeExpression
{
  deLine line = deExpressionGetLine($1);
  deStatement statement = createBlockStatement(DE_STATEMENT_CASE, line);
  $$ = deExpressionCreate(DE_EXPR_LIST, deExpressionGetLine($1));
  deStatementInsertExpression(statement, $$);
  deExpressionAppendExpression($$, $1);
}
| typeswitchCaseHeaders ',' optNewlines typeExpression
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

exceptCaseHeaders: pathExpression
{
  deLine line = deExpressionGetLine($1);
  deStatement statement = createBlockStatement(DE_STATEMENT_CASE, line);
  $$ = deExpressionCreate(DE_EXPR_LIST, deExpressionGetLine($1));
  deStatementInsertExpression(statement, $$);
  deExpressionAppendExpression($$, $1);
}
| exceptCaseHeaders ',' optNewlines pathExpression
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

optDefaultCase: // Empty
{
  // If default is missing, add one with a raise statement.
  createBlockStatement(DE_STATEMENT_DEFAULT, deCurrentLine);
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_RAISE, deCurrentLine);
  deExpression expression = deExpressionCreate(DE_EXPR_LIST, deCurrentLine);
  deExpression exceptionEnum = deIdentExpressionCreate(utSymCreate("Exception"), deCurrentLine);
  deExpression enumVal = deIdentExpressionCreate(utSymCreate("NoMatchFound"), deCurrentLine);
  deExpression dotExpr = deBinaryExpressionCreate(DE_EXPR_DOT,
      exceptionEnum, enumVal, deCurrentLine);
  deExpressionAppendExpression(expression, dotExpr);
  deExpression message = deStringExpressionCreate(
      deMutableCStringCreate("No case matched switch expression"), deCurrentLine);
  deExpressionAppendExpression(expression, message);
  deStatementInsertExpression(statement, expression);
  finishBlockStatement(deExpressionNull);
}
| defaultCaseHeader KWIMPLIES block
{
  finishBlockStatement(deExpressionNull);
}
| defaultCaseHeader KWIMPLIES statement
{
  finishBlockStatement(deExpressionNull);
}

defaultCaseHeader: KWDEFAULT
{
  createBlockStatement(DE_STATEMENT_DEFAULT, $1);
}

whileStatement: optDoStatement whileStatementHeader expression newlines
{
  deBlock subBlock = deCurrentBlock;
  finishBlockStatement($3);
  deBlockDestroy(subBlock);
}
| optDoStatement whileStatementHeader expression block
{
  finishBlockStatement($3);
}

whileStatementHeader: KWWHILE
{
  createBlockStatement(DE_STATEMENT_WHILE, $1);
}

optDoStatement: // Empty
| doStatement

doStatement: doStatementHeader block
{
  finishBlockStatement(deExpressionNull);
}

doStatementHeader: KWDO
{
  createBlockStatement(DE_STATEMENT_DO, $1);
}

forStatement: forStatementHeader assignmentExpression ',' optNewlines expression ','
	    optNewlines assignmentExpression block
{
  deStatement statement = deBlockGetOwningStatement(deCurrentBlock);
  deExpression expressionList = deExpressionCreate(DE_EXPR_LIST, deStatementGetLine(statement));
  deExpressionAppendExpression(expressionList, $2);
  deExpressionAppendExpression(expressionList, $5);
  deExpressionAppendExpression(expressionList, $8);
  finishBlockStatement(expressionList);
}

forStatementHeader: KWFOR
{
  // Also used to start foreach statements.
  createBlockStatement(DE_STATEMENT_FOR, $1);
}

assignmentStatement: assignmentExpression newlines
{
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_ASSIGN,
  deExpressionGetLine($1));
  deStatementInsertExpression(statement, $1);
}

assignmentExpression: writableExpression optTypeExpression assignmentOp expression
{
  $$ = deBinaryExpressionCreate($3, $1, $4, deExpressionGetLine($1));
  if ($2 != deExpressionNull) {
    deExpressionAppendExpression($$, $2);  // Add type constraint as 3rd parameter.
  }
}

assignmentOp: '='
{
  $$ = DE_EXPR_EQUALS;
}
| KWADDEQUALS
{
  $$ = DE_EXPR_ADD_EQUALS;
}
| KWSUBEQUALS
{
  $$ = DE_EXPR_SUB_EQUALS;
}
| KWMULEQUALS
{
  $$ = DE_EXPR_MUL_EQUALS;
}
| KWDIVEQUALS
{
  $$ = DE_EXPR_DIV_EQUALS;
}
| KWMODEQUALS
{
  $$ = DE_EXPR_MOD_EQUALS;
}
| KWBITANDEQUALS
{
  $$ = DE_EXPR_BITAND_EQUALS;
}
| KWBITOREQUALS
{
  $$ = DE_EXPR_BITOR_EQUALS;
}
| KWBITXOREQUALS
{
  $$ = DE_EXPR_BITXOR_EQUALS;
}
| KWANDEQUALS
{
  $$ = DE_EXPR_AND_EQUALS;
}
| KWOREQUALS
{
  $$ = DE_EXPR_OR_EQUALS;
}
| KWXOREQUALS
{
  $$ = DE_EXPR_XOR_EQUALS;
}
| KWEXPEQUALS
{
  $$ = DE_EXPR_EXP_EQUALS;
}
| KWSHLEQUALS
{
  $$ = DE_EXPR_SHL_EQUALS;
}
| KWSHREQUALS
{
  $$ = DE_EXPR_SHR_EQUALS;
}
| KWROTLEQUALS
{
  $$ = DE_EXPR_ROTL_EQUALS;
}
| KWROTREQUALS
{
  $$ = DE_EXPR_ROTR_EQUALS;
}
| KWADDTRUNCEQUALS
{
  $$ = DE_EXPR_ADDTRUNC_EQUALS;
}
| KWSUBTRUNCEQUALS
{
  $$ = DE_EXPR_SUBTRUNC_EQUALS;
}
| KWMULTRUNCEQUALS
{
  $$ = DE_EXPR_MULTRUNC_EQUALS;
}

optTypeExpression: // Empty
{
  $$ = deExpressionNull;
}
| ':' typeExpression
{
  $$ = $2;
}

typeExpression: typeRangeExpression
| typeExpression '|' typeRangeExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_BITOR, $1, $3, $2);
}

typeRangeExpression: compoundTypeExpression
| typeLiteral KWDOTDOTDOT typeLiteral
{
  $$ = deBinaryExpressionCreate(DE_EXPR_DOTDOTDOT, $1, $3, $2);
}

compoundTypeExpression: basicTypeExpression
| '[' typeRangeExpressionList ']'
{
  // Modify the type from DE_EXPR_LIST to DE_EXPR_ARRAY.
  deExpressionSetType($2, DE_EXPR_ARRAY);
  $$ = $2;
}
| '(' typeRangeExpressionList ')'
{
  // Modify the type from DE_EXPR_LIST to DE_EXPR_TUPLE.
  deExpressionSetType($2, DE_EXPR_TUPLE);
  $$ = $2;
}
| '(' ')'
{
  $$ = deExpressionCreate(DE_EXPR_TUPLE, $1);
}

typeRangeExpressionList: typeRangeExpression
{
  $$ = deUnaryExpressionCreate(DE_EXPR_LIST, $1, deExpressionGetLine($1));
}
| typeRangeExpressionList ',' typeRangeExpression
{
  deExpressionAppendExpression($1, $3);
}

basicTypeExpression: typePathExpression
| KWTYPEOF '(' expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_TYPEOF, $3, $1);
}
| KWUNSIGNED '(' expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_UNSIGNED, $3, $1);
}
| KWSIGNED '(' expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_SIGNED, $3, $1);
}
| typeLiteral
| typePathExpression '?'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_NULL, $1, $2);
}
| KWSECRET '(' typeRangeExpression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_SECRET, $3, $1);
}

typePathExpression: pathExpression
| pathExpression  '<' oneOrMoreTypeExpressions '>'
{
  $$ = deBinaryExpressionCreate(DE_EXPR_TEMPLATE_INST, $1, $3, $2);
}

oneOrMoreTypeExpressions: typeExpression
{
  $$ = deExpressionCreate(DE_EXPR_LIST, deCurrentLine);
  deExpressionAppendExpression($$, $1);
}
| oneOrMoreTypeExpressions ',' typeExpression
{
  deExpressionAppendExpression($1, $3);
  $$ = $1;
}

optFuncTypeExpression: // Empty
{
  $$ = deExpressionNull;
}
| KWARROW typeExpression
{
  $$ = $2;
}

// Access expressions are things that can be followed by dot or index.
accessExpression: writableExpression
| callExpression
| tokenExpression
| STRING  // Not a token expression, e.g. "test".length().
{
  $$ = deStringExpressionCreate($1, deCurrentLine);
}
| accessExpression '[' expression ':' expression ']'
{
  $$ = deBinaryExpressionCreate(DE_EXPR_SLICE, $1, $3, $2);
  deExpressionAppendExpression($$, $5);
}
| accessExpression '!'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_NOTNULL, $1, $2);
}
| '[' oneOrMoreExpressions ']'
{
  // Modify the type from DE_EXPR_LIST to DE_EXPR_ARRAY.
  deExpressionSetType($2, DE_EXPR_ARRAY);
  $$ = $2;
}
| '(' expression ')'
{
  $$ = $2;
}
| tupleExpression
| KWSECRET '(' expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_SECRET, $3, $1);
}
| KWREVEAL '(' expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_REVEAL, $3, $1);
}
| KWARRAYOF '(' typeExpression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_ARRAYOF, $3, $1);
}
| KWTYPEOF '(' expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_TYPEOF, $3, $1);
}
| KWNULL '(' callParameterList ')'
{
  deExpressionSetType($3, DE_EXPR_NULL);
  $$ = $3;
}
| '&' pathExpression '(' expressionList ')'
{
  deExpression callExpr = deBinaryExpressionCreate(DE_EXPR_CALL, $2, $4, $1);
  $$ = deUnaryExpressionCreate(DE_EXPR_FUNCADDR, callExpr, $1);
}

writableExpression: IDENT
{
  $$ = deIdentExpressionCreate($1, deCurrentLine);
}
| accessExpression '.' IDENT
{
  deExpression identExpr = deIdentExpressionCreate($3, $2);
  $$ = deBinaryExpressionCreate(DE_EXPR_DOT, $1, identExpr, $2);
}
| accessExpression '[' expression ']'
{
  $$ = deBinaryExpressionCreate(DE_EXPR_INDEX, $1, $3, $2);
}

tokenExpression: INTEGER
{
  $$ = deIntegerExpressionCreate($1, deCurrentLine);
}
| FLOAT
{
  $$ = deFloatExpressionCreate($1, deCurrentLine);
}
| RANDUINT
{
  $$ = deRandUintExpressionCreate($1, deCurrentLine);
}
| BOOL
{
  $$ = deBoolExpressionCreate($1, deCurrentLine);
}
| typeLiteral
| returnsTokenExpression

callExpression: accessExpression '(' callParameterList ')'
{
  $$ = deBinaryExpressionCreate(DE_EXPR_CALL, $1, $3, deExpressionGetLine($1));
}

callStatement: accessExpression '(' callParameterList ')' newlines
{
  deExpression expr = deBinaryExpressionCreate(DE_EXPR_CALL, $1, $3, $2);
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_CALL, $2);
  deStatementInsertExpression(statement, expr);
}

optCallParameterList:  // Empty
{
  $$ = deExpressionCreate(DE_EXPR_LIST, deCurrentLine);
}
| '(' oneOrMoreCallParameters ')'
{
  $$ = $2;
}

callParameterList: // Empty
{
  // Create an empty expression list.
  $$ = deExpressionCreate(DE_EXPR_LIST, deCurrentLine);
}
| oneOrMoreCallParameters optComma
{
}

oneOrMoreCallParameters: callParameter
{
  $$ = deExpressionCreate(DE_EXPR_LIST, deExpressionGetLine($1));
  deExpressionAppendExpression($$, $1);
}
| oneOrMoreCallParameters ',' optNewlines callParameter
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

callParameter: expression
| IDENT '=' expression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_NAMEDPARAM, deIdentExpressionCreate($1, $2), $3, $2);
}

optComma:  // Empty
| ','

printStatement: KWPRINT expressionList newlines
{
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_PRINT, $1);
  if ($2 != deExpressionNull) {
    deExpressionSetType($2, DE_EXPR_LIST);
    deStatementInsertExpression(statement, $2);
  }
}

printlnStatement: KWPRINTLN expressionList newlines
{
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_PRINT, $1);
  deExpression expression = $2;
  if (expression == deExpressionNull) {
    expression = deExpressionCreate(DE_EXPR_LIST, deCurrentLine);
  }
  deExpression lastExpression = deExpressionGetLastExpression(expression);
  if (lastExpression == deExpressionNull || deExpressionGetType(lastExpression) != DE_EXPR_STRING) {
    // Just add a \n parameter at the end of a print statement.
    deString newline = deMutableCStringCreate("\n");
    deExpressionAppendExpression(expression, deStringExpressionCreate(newline, $1));
  } else {
    //  Append the \n to the last string.
    deString string = deExpressionGetString(lastExpression);
    uint32 len = deStringGetNumText(string);
    deStringResizeTexts(string, len + 1);
    deStringSetiText(string, len, '\n');
  }
  deStatementInsertExpression(statement, expression);
}

tryExceptStatements: tryStatement exceptStatement

tryStatement: tryHeader block
{
  finishBlockStatement(deExpressionNull);
}

tryHeader: KWTRY
{
  createBlockStatement(DE_STATEMENT_TRY, $1);
}

exceptStatement: exceptHeader IDENT exceptBlock
{
  deLine line = deBlockGetLine(deCurrentBlock);
  deExpression identExpr = deIdentExpressionCreate($2, line);
  // Capture the global runtimeException in variable IDENT.
  deExpression errorExpr = deIdentExpressionCreate(utSymCreate("runtimeException"), line);
  deExpression assignExpr = deBinaryExpressionCreate(DE_EXPR_EQUALS, identExpr, errorExpr, line);
  finishBlockStatement(assignExpr);
}

exceptHeader: KWEXCEPT
{
  createBlockStatement(DE_STATEMENT_EXCEPT, $1);
}

raiseStatement: KWRAISE raiseExpressionList newlines
{
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_RAISE, $1);
  deStatementInsertExpression(statement, $2);
}

raiseExpressionList: pathExpression
{
  $$ = deExpressionCreate(DE_EXPR_LIST, deExpressionGetLine($1));
  deExpressionAppendExpression($$, $1);
}
| raiseExpressionList ',' optNewlines expression
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

panicStatement: KWPANIC expressionList newlines
{
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_RAISE, $1);
  deExpression enumNameExpr = deIdentExpressionCreate(utSymCreate("Exception"), $1);
  deExpression enumValueExpr = deIdentExpressionCreate(utSymCreate("Panic"), $1);
  deExpression enumExpr = deBinaryExpressionCreate(DE_EXPR_DOT, enumNameExpr, enumValueExpr, $1);
  deExpressionInsertExpression($2, enumExpr);
  deStatementInsertExpression(statement, $2);
}


assertStatement: KWASSERT expressionList newlines
{
  deStatement ifStatement = createBlockStatement(DE_STATEMENT_IF, $1);
  deBlock subBlock = deStatementGetSubBlock(ifStatement);
  deStatement statement = deStatementCreate(subBlock, DE_STATEMENT_RAISE, $1);
  deStatementInsertExpression(statement, $2);
  deExpression condition = deExpressionGetFirstExpression($2);
  deExpressionRemoveExpression($2, condition);
  deString text = deMutableCStringCreate(utSprintf("%s:%u %s",
    deFilepathGetRelativePath(deCurrentFilepath),
    deLineGetLineNum($1), deLineGetText($1)));
  deExpressionInsertExpression($2, deStringExpressionCreate(text, $1));
  deExpression enumNameExpr = deIdentExpressionCreate(utSymCreate("Exception"), $1);
  deExpression enumValueExpr = deIdentExpressionCreate(utSymCreate("AssertionFailure"), $1);
  deExpression enumExpr = deBinaryExpressionCreate(DE_EXPR_DOT, enumNameExpr, enumValueExpr, $1);
  deExpressionInsertExpression($2, enumExpr);
  deStatementInsertExpression(statement, $2);
  condition = deUnaryExpressionCreate(DE_EXPR_NOT, condition, $1);
  finishBlockStatement(condition);
}

returnStatement: KWRETURN newlines
{
  deStatementCreate(deCurrentBlock, DE_STATEMENT_RETURN, $1);
}
| KWRETURN expression newlines
{
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_RETURN, $1);
  deStatementInsertExpression(statement, $2);
  deBlock scopeBlock = deBlockGetScopeBlock(deCurrentBlock);
  deFunction function = deBlockGetOwningFunction(scopeBlock);
  deFunctionSetReturnsValue(function, true);
}

transformer: transformerHeader '(' parameters ')' block
{
  deInTransformer = false;
  deCurrentBlock = deBlockGetOwningBlock(deCurrentBlock);
}

transformerHeader: KWTRANSFORMER IDENT
{
  if (deInTransformer) {
    deError($1, "Cannot embed a generator inside another generator");
  }
  checkTopBlock("Generator");
  deTransformer transformer = deTransformerCreate(deCurrentBlock, $2, $1);
  deCurrentBlock = deTransformerGetSubBlock(transformer);
  deInTransformer = true;
}

transformStatement: KWTRANSFORM pathExpression '(' expressionList ')' newlines
{
  checkTopBlock("Transform");
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_TRANSFORM, $1);
  deExpression callExpr = deBinaryExpressionCreate(DE_EXPR_CALL, $2, $4, $1);
  deStatementInsertExpression(statement, callExpr);
}

relationStatement: KWRELATION pathExpression typePathExpression optLabel typePathExpression optLabel optCascade optCallParameterList newlines
{
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_RELATION, $1);
  deExpression params = $8;
  deExpressionInsertExpression(params, $6);  // optLabel
  deExpressionInsertExpression(params, $4);  // optLabel
  deExpressionInsertExpression(params, $7);  // optCascade
  deExpressionInsertExpression(params, $5);  // child class
  deExpressionInsertExpression(params, $3);  // parent class
  deExpression callExpr = deBinaryExpressionCreate(DE_EXPR_CALL, $2, params, $1);
  deStatementInsertExpression(statement, callExpr);
  // Move it to the start of the block.
  deBlockRemoveStatement(deCurrentBlock, statement);
  deBlockInsertStatement(deCurrentBlock, statement);
}

optLabel: // Empty
{
  $$ = deStringExpressionCreate(deMutableCStringCreate(""), deCurrentLine);
}
| ':' STRING
{
  $$ = deStringExpressionCreate($2, $1);
}

optCascade: // Empty
{
  $$ = deBoolExpressionCreate(false, deCurrentLine);
}
| KWCASCADE
{
  $$ = deBoolExpressionCreate(true, $1);
}

// Only allowed inside iterator block.
yield: KWYIELD expression newlines
{
  if (!deInIterator) {
    deError($1, "Yield statement can only be used inside iterator definitions.");
  }
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_YIELD, $1);
  deStatementSetExpression(statement, $2);
}

unitTest: namedUnitTestHeader block
{
  deFunction function = deBlockGetOwningFunction(deCurrentBlock);
  deCurrentBlock = deFunctionGetBlock(function);
  if (!deTestMode && !deParsingMainModule) {
    deFunctionDestroy(function);
  } else {
    deBlock subBlock = deFunctionGetSubBlock(function);
    moveImportsToBlock(subBlock, deCurrentBlock);
    // Call the unit test.
    deLine line = deFunctionGetLine(function);
    deExpression accessExpr = deIdentExpressionCreate(deFunctionGetSym(function), line);
    deExpression paramsExpr = deExpressionCreate(DE_EXPR_LIST, line);
    deExpression callExpr = deBinaryExpressionCreate(DE_EXPR_CALL, accessExpr, paramsExpr, line);
    deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_CALL, line);
    deStatementInsertExpression(statement, callExpr);
  }
  deInIterator = false;
  deInUnitTest = false;
}
| unnamedUnitTestHeader block
{
  if (!deTestMode && !deParsingMainModule) {
    deStatement statement = deBlockGetOwningStatement(deCurrentBlock);
    deCurrentBlock = deStatementGetBlock(statement);
    deStatementDestroy(statement);
    deSkippedCodeNestedDepth--;
    deInUnitTest = false;
  }
}

namedUnitTestHeader: KWUNITTEST IDENT
{
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_UNITTEST, $2, DE_LINK_MODULE, $1);
  deFunctionSetInUnitTest(function, true);
  deCurrentBlock = deFunctionGetSubBlock(function);
  deInUnitTest = true;
}

unnamedUnitTestHeader: KWUNITTEST
{
  if (!deTestMode && !deParsingMainModule) {
    deSkippedCodeNestedDepth++;
    // Statements in this block will be destroyed above.
    createBlockStatement(DE_STATEMENT_DO, $1);
  } else {
    deInUnitTest = true;
  }
}

debugStatement: debugHeader block
{
  if (!deDebugMode) {
    // Destroy debug code when not in debug mode.
    deStatement statement = deBlockGetOwningStatement(deCurrentBlock);
    deCurrentBlock = deStatementGetBlock(statement);
    deStatementDestroy(statement);
    deSkippedCodeNestedDepth--;
  }
}

debugHeader: KWDEBUG
{
  if (!deDebugMode) {
    deSkippedCodeNestedDepth++;
    createBlockStatement(DE_STATEMENT_DO, $1);
  }
}

enum: enumHeader '{' newlines entries '}' newlines
{
  deAssignEnumEntryConstants(deCurrentBlock);
  deCurrentBlock = deBlockGetOwningBlock(deCurrentBlock);
}

enumHeader: KWENUM IDENT
{
  deFunction enumFunc = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_ENUM, $2, DE_LINK_MODULE, $1);
  deFunctionSetInUnitTest(enumFunc, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(enumFunc);
}

entries:  // Empty
| entries entry

entry: IDENT newlines
{
  deVariableCreate(deCurrentBlock, DE_VAR_LOCAL, true, $1, deExpressionNull,
      false, deCurrentLine);
}
| IDENT '=' INTEGER newlines
{
  deExpression intExpr = deIntegerExpressionCreate($3, $2);
  if (deBigintGetWidth(deExpressionGetBigint(intExpr)) > 32) {
    deError($2, "Enumerated types must fit in 32 bit integers.");
  }
  deVariableCreate(deCurrentBlock, DE_VAR_LOCAL, true, $1, intExpr, false, $2);
}

foreachStatement: forStatementHeader IDENT KWIN expression block
{
  deStatement statement = deBlockGetOwningStatement(deCurrentBlock);
  // Change the statement type to FOREACH here to avoid shift-reduce conflict.
  deStatementSetType(statement, DE_STATEMENT_FOREACH);
  deExpression expr = deBinaryExpressionCreate(DE_EXPR_EQUALS,
      deIdentExpressionCreate($2, $3), $4, $3);
  finishBlockStatement(expr);
}

finalFunction: finalHeader '(' parameter ')' optRaises block
{
  deFunction function = deBlockGetOwningFunction(deCurrentBlock);
  deCurrentBlock = deFunctionGetBlock(function);
}

finalHeader: KWFINAL
{
  deBlock scopeBlock = deBlockGetScopeBlock(deCurrentBlock);
  if (deBlockGetType(scopeBlock) != DE_BLOCK_FUNCTION) {
    deError($1, "final(self) functions only allowed inside constructors");
  }
  deFunction constructor = deBlockGetOwningFunction(scopeBlock);
  if (deFunctionGetType(constructor) != DE_FUNC_CONSTRUCTOR) {
    deError($1, "final(self) functions only allowed inside constructors");
  }
  deTemplate templ = deFunctionGetTemplate(constructor);
  deTemplateSetHasFinalMethod(templ, true);
  deFunction function = deFunctionCreate(deCurrentFilepath, deCurrentBlock,
      DE_FUNC_PLAIN, utSymCreate("final"), DE_LINK_MODULE, $1);
  deFunctionSetInUnitTest(function, deInUnitTest);
  deCurrentBlock = deFunctionGetSubBlock(function);
}

optRaises:  // Empty
| KWRAISES oneOrMorePathExpressions

oneOrMorePathExpressions: pathExpression
{
  $$ = deExpressionCreate(DE_EXPR_LIST, deExpressionGetLine($1));
  deExpressionAppendExpression($$, $1);
}
| oneOrMorePathExpressions ',' optNewlines pathExpression
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

refStatement: KWREF expression newlines
{
  if (!deGenerating) {
    deError($1, "Ref statements are only allowed in generators");
  }
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_REF, $1);
  deStatementSetExpression(statement, $2);
}

unrefStatement: KWUNREF expression newlines
{
  if (!deGenerating) {
    deError($1, "Unref statements are only allowed in generators");
  }
  deStatement statement = deStatementCreate(deCurrentBlock, DE_STATEMENT_UNREF, $1);
  deStatementSetExpression(statement, $2);
}

expressionList: // Empty
{
  // Create an empty expression list.
  $$ = deExpressionCreate(DE_EXPR_LIST, deCurrentLine);
}
| oneOrMoreExpressions

oneOrMoreExpressions: expression
{
  $$ = deExpressionCreate(DE_EXPR_LIST, deExpressionGetLine($1));
  deExpressionAppendExpression($$, $1);
}
| oneOrMoreExpressions ',' optNewlines expression
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

twoOrMoreExpressions: expression ',' optNewlines expression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_TUPLE, $1, $4, $2);
}
| twoOrMoreExpressions ',' optNewlines expression
{
  deExpressionAppendExpression($1, $4);
  $$ = $1;
}

expression: dotDotDotExpression

dotDotDotExpression: selectExpression KWDOTDOTDOT selectExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_DOTDOTDOT, $1, $3, $2);
}
| selectExpression

selectExpression: orExpression
| orExpression '?' optNewlines orExpression ':' optNewlines orExpression
{
  deExpression expr = deExpressionCreate(DE_EXPR_SELECT, $2);
  deExpressionAppendExpression(expr, $1);
  deExpressionAppendExpression(expr, $4);
  deExpressionAppendExpression(expr, $7);
  $$ = expr;
}

orExpression: xorExpression
| orExpression KWOR optNewlines xorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_OR, $1, $4, $2);
}

xorExpression: andExpression
| xorExpression KWXOR optNewlines andExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_XOR, $1, $4, $2);
}

andExpression: inExpression
| andExpression KWAND optNewlines inExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_AND, $1, $4, $2);
}

inExpression: modExpression
| modExpression KWIN optNewlines modExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_IN, $1, $4, $2);
}

modExpression: relationExpression
| relationExpression KWMOD optNewlines bitorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_MODINT, $1, $4, deExpressionGetLine($1));
}

relationExpression: bitorExpression
| bitorExpression '<' optNewlines bitorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_LT, $1, $4, deExpressionGetLine($1));
}
| bitorExpression KWLE optNewlines bitorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_LE, $1, $4, deExpressionGetLine($1));
}
| bitorExpression '>' optNewlines bitorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_GT, $1, $4, deExpressionGetLine($1));
}
| bitorExpression KWGE optNewlines bitorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_GE, $1, $4, deExpressionGetLine($1));
}
| bitorExpression KWEQUAL optNewlines bitorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_EQUAL, $1, $4, deExpressionGetLine($1));
}
| bitorExpression KWNOTEQUAL optNewlines bitorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_NOTEQUAL, $1, $4, deExpressionGetLine($1));
}

bitorExpression: bitxorExpression
| bitorExpression '|' optNewlines bitxorExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_BITOR, $1, $4, $2);
}

bitxorExpression: bitandExpression
| bitxorExpression '^' optNewlines bitandExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_BITXOR, $1, $4, $2);
}

bitandExpression: shiftExpression
| bitandExpression '&' optNewlines shiftExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_BITAND, $1, $4, $2);
}

shiftExpression: addExpression
| addExpression KWSHL optNewlines addExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_SHL, $1, $4, $2);
}
| addExpression KWSHR optNewlines addExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_SHR, $1, $4, $2);
}
| addExpression KWROTL optNewlines addExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_ROTL, $1, $4, $2);
}
| addExpression KWROTR optNewlines addExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_ROTR, $1, $4, $2);
}

addExpression: mulExpression
| addExpression '+' optNewlines mulExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_ADD, $1, $4, $2);
}
| addExpression '-' optNewlines mulExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_SUB, $1, $4, $2);
}
| KWSUBTRUNC mulExpression
{
  $$ = deUnaryExpressionCreate(DE_EXPR_NEGATETRUNC, $2, $1);
}
| addExpression KWADDTRUNC optNewlines mulExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_ADDTRUNC, $1, $4, $2);
}
| addExpression KWSUBTRUNC optNewlines mulExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_SUBTRUNC, $1, $4, $2);
}

mulExpression: prefixExpression
| mulExpression '*' optNewlines prefixExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_MUL, $1, $4, $2);
}
| mulExpression '/' optNewlines prefixExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_DIV, $1, $4, $2);
}
| mulExpression '%' optNewlines prefixExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_MOD, $1, $4, $2);
}
| mulExpression KWMULTRUNC optNewlines prefixExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_MULTRUNC, $1, $4, $2);
}

prefixExpression: exponentiateExpression
| '!' prefixExpression
{
  $$ = deUnaryExpressionCreate(DE_EXPR_NOT, $2, $1);
}
| '~' prefixExpression
{
  $$ = deUnaryExpressionCreate(DE_EXPR_BITNOT, $2, $1);
}
| '-' prefixExpression
{
  $$ = deUnaryExpressionCreate(DE_EXPR_NEGATE, $2, $1);
}
| '<' typeExpression '>' prefixExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_CAST, $2, $4, $1);
}
| KWCASTTRUNC typeExpression '>' prefixExpression
{
  $$ = deBinaryExpressionCreate(DE_EXPR_CASTTRUNC, $2, $4, $1);
}

exponentiateExpression: accessExpression
| accessExpression KWEXP optNewlines exponentiateExpression  // Binds right to left.
{
  $$ = deBinaryExpressionCreate(DE_EXPR_EXP, $1, $4, $2);
}

// These expresions are known to return integer or Boolean values,
// and can be treated like tokens.
returnsTokenExpression: KWUNSIGNED '(' optNewlines expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_UNSIGNED, $4, $1);
}
| KWSIGNED '(' optNewlines expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_SIGNED, $4, $1);
}
| KWWIDTHOF '(' optNewlines expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_WIDTHOF, $4, $1);
}
| KWISNULL '(' optNewlines expression ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_ISNULL, $4, $1);
}

typeLiteral: UINTTYPE
{
  $$ = deExpressionCreate(DE_EXPR_UINTTYPE, deCurrentLine);
  deExpressionSetWidth($$, $1);
}
| INTTYPE
{
  $$ = deExpressionCreate(DE_EXPR_INTTYPE, deCurrentLine);
  deExpressionSetWidth($$, $1);
}
| KWSTRING
{
  $$ = deExpressionCreate(DE_EXPR_STRINGTYPE, deCurrentLine);
}
| KWBOOL
{
  $$ = deExpressionCreate(DE_EXPR_BOOLTYPE, deCurrentLine);
}
| KWNONE
{
  $$ = deExpressionCreate(DE_EXPR_NONETYPE, deCurrentLine);
}
| KWF32
{
  $$ = deExpressionCreate(DE_EXPR_FLOATTYPE, deCurrentLine);
  deExpressionSetWidth($$, 32);
}
| KWF64
{
  $$ = deExpressionCreate(DE_EXPR_FLOATTYPE, deCurrentLine);
  deExpressionSetWidth($$, 64);
}

pathExpression: IDENT
{
  $$ = deIdentExpressionCreate($1, deCurrentLine);
}
| pathExpression '.' IDENT
{
  $$ = deBinaryExpressionCreate(
      DE_EXPR_DOT, $1, deIdentExpressionCreate($3, $2), $2);
}

pathExpressionWithAlias: pathExpression
| pathExpression KWAS IDENT
{
  $$ = deBinaryExpressionCreate(
      DE_EXPR_AS, $1, deIdentExpressionCreate($3, $2), $2);
}

tupleExpression: '(' twoOrMoreExpressions optComma ')'
{
  $$ = $2;
}
| '(' expression ',' ')'
{
  $$ = deUnaryExpressionCreate(DE_EXPR_TUPLE, $2, $1);
}
| '(' ')'
{
  $$ = deExpressionCreate(DE_EXPR_TUPLE, $1);
}

optNewlines: // Empty
| optNewlines '\n'

newlines: '\n'
| ';'
| newlines '\n'
| newlines ';'

%%

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

#include "de.h"

// Generate an assignment statement, after |statement|.
static deStatement assignVariable(deStatement statement, deVariable variable, deExpression value) {
  deExpression valueCopy = deCopyExpression(value);
  deLine line = deStatementGetLine(statement);
  deBlock block = deStatementGetBlock(statement);
  deStatement assignmentState = deStatementCreate(block, DE_STATEMENT_ASSIGN, line);
  deBlockRemoveStatement(block, assignmentState);
  deBlockInsertAfterStatement(block, statement, assignmentState);
  deExpression identExpr = deIdentExpressionCreate(deVariableGetSym(variable), line);
  deExpression assignmentExpr =
      deBinaryExpressionCreate(DE_EXPR_EQUALS, identExpr, valueCopy, line);
  deStatementInsertExpression(assignmentState, assignmentExpr);
  return assignmentState;
}

// Create assign statements to set the iterators's parameters.
static deStatement assignIteratorParameters(deStatement statement,
    deBlock iteratorBlock, deExpression parameters, bool isMethodCall) {
  uint32 numParamExprs = deExpressionCountExpressions(parameters);
  uint32 numParamVars = deBlockCountParameterVariables(iteratorBlock);
  if (numParamVars == 0) {
    return statement;
  }
  deVariable variable = deBlockIndexVariable(iteratorBlock, numParamVars - 1);
  if (isMethodCall) {
    numParamVars--;  // Deal with self separately.
  }
  deExpression param = deExpressionNull;
  if (numParamVars != 0) {
    param = deExpresssionIndexExpression(parameters, numParamExprs - 1);
  }
  for (uint32 i = 0; i < numParamVars; i++) {
    if (i < numParamVars - numParamExprs) {
      // Use default value.
      deExpression value = deVariableGetInitializerExpression(variable);
      statement = assignVariable(statement, variable, value);
    } else {
      statement = assignVariable(statement, variable, param);
      param = deExpressionGetPrevExpression(param);
    }
    variable = deVariableGetPrevBlockVariable(variable);
  }
  return statement;
}

// Recursively search for a yield statement in the block.
static deStatement findStatementYieldStatement(deStatement statement) {
  if (deStatementGetType(statement) == DE_STATEMENT_YIELD && deStatementInstantiated(statement)) {
    return statement;
  }
  deBlock subBlock = deStatementGetSubBlock(statement);
  if (subBlock == deBlockNull) {
    return deStatementNull;
  }
  deStatement firstYieldStatement = deStatementNull;
  deStatement subStatement;
  deForeachBlockStatement(subBlock, subStatement) {
    deStatement yieldStatement = findStatementYieldStatement(subStatement);
    if (yieldStatement != deStatementNull && deStatementInstantiated(statement)) {
      if (firstYieldStatement != deStatementNull) {
        deLine line = deStatementGetLine(yieldStatement);
        deError(line, "Only one yield statement per iterator is currently supported");
      }
      firstYieldStatement = yieldStatement;
    }
  } deEndBlockStatement;
  return firstYieldStatement;
}

// Recursively search for a yield statement in the range of statements, not
// including |lastStatement|.  Report an error if multiple yield statements are
// found.
static deStatement findYieldStatement(deStatement firstStatement, deStatement lastStatement) {
  deStatement firstYieldStatement = deStatementNull;
  while (firstStatement != lastStatement) {
    deStatement yieldStatement = findStatementYieldStatement(firstStatement);
    if (yieldStatement != deStatementNull) {
      if (firstYieldStatement != deStatementNull) {
        deLine line = deStatementGetLine(yieldStatement);
        deError(line, "Only one yield statement per iterator is currently supported");
      }
      firstYieldStatement = yieldStatement;
    }
    firstStatement = deStatementGetNextBlockStatement(firstStatement);
  }
  if (firstYieldStatement == deStatementNull) {
    deLine line = deStatementGetLine(firstStatement);
    deError(line, "No yield statement found in iterator");
  }
  return firstYieldStatement;
}
// Turn the yield statement into an assignment.
static void turnYieldIntLoopVarAssignment(deStatement yieldStatement, deExpression assignment) {
  deExpression access = deExpressionGetFirstExpression(assignment);
  deExpression call = deExpressionGetNextExpression(access);
  deStatementSetType(yieldStatement, DE_STATEMENT_ASSIGN);
  deExpression yieldValue = deStatementGetExpression(yieldStatement);
  deStatementRemoveExpression(yieldStatement, yieldValue);
  deExpressionDestroy(call);
  deExpressionAppendExpression(assignment, yieldValue);
  deStatementRemoveExpression(deExpressionGetStatement(assignment), assignment);
  deStatementInsertExpression(yieldStatement, assignment);
}

// Find the selected case statement in a switch-type statement.
static deStatement findSelectedCase(deStatement switchStatement) {
  deBlock subBlock = deStatementGetSubBlock(switchStatement);
  deStatement caseStatement;
  deForeachBlockStatement(subBlock, caseStatement) {
    if (deStatementInstantiated(caseStatement)) {
      return caseStatement;
    }
  } deEndBlockStatement;
  utExit("Could not find instantiated case statement");
  return deStatementNull;
}

// Forward declaration for recursion.
static deStatement flattenSwitchTypeStatements(deStatement firstStatement,
    deStatement lastStatement);

// If this is a switch-type statement, replace it with the contents of the
// selected case block.  Recurse into sub-blocks to flatten sub-switch
// statements.
static void flattenSwitchTypeStatement(deStatement statement) {
  deExpression expression = deStatementGetExpression(statement);
  if (deStatementGetType(statement) != DE_STATEMENT_SWITCH ||
      !deExpressionIsType(expression)) {
    return;
  }
  deStatement selectedCase = findSelectedCase(statement);
  deBlock body = deStatementGetSubBlock(selectedCase);
  if (deBlockGetFirstStatement(body) != deStatementNull) {
    deStatement lastStatement = deStatementGetNextBlockStatement(statement);
    deMoveBlockStatementsAfterStatement(body, statement);
    deStatement firstStatement = deStatementGetNextBlockStatement(statement);
    deStatementDestroy(statement);
    flattenSwitchTypeStatements(firstStatement, lastStatement);
  } else {
    deStatementDestroy(statement);
  }
}

// Return the first non-destroyed statement in the range.
static deStatement flattenSwitchTypeStatements(deStatement firstStatement,
    deStatement lastStatement) {
  deStatement nextStatement;
  for (deStatement statement = firstStatement; statement != lastStatement;
      statement = nextStatement) {
    nextStatement = deStatementGetNextBlockStatement(statement);
    flattenSwitchTypeStatement(statement);
  }
  return firstStatement;
}

// Queue statements from firstStatement to lastStatement for binding.
static void queueStatements(deStatement firstStatement, deStatement lastStatement) {
  do {
    deQueueStatement(deCurrentSignature, firstStatement, true);
    firstStatement = deStatementGetNextBlockStatement(firstStatement);
  } while (firstStatement != lastStatement);
}

// Inline the iterator.  The statement should already be bound.  Return the
// statement replacing the one passed in.
deStatement deInlineIterator(deBlock scopeBlock, deStatement statement) {
  bool savedInIterator = deInIterator;
  deInIterator = true;
  deExpression assignment = deStatementGetExpression(statement);
  deExpression access = deExpressionGetFirstExpression(assignment);
  deExpression call = deExpressionGetNextExpression(access);
  deLine line = deExpressionGetLine(call);
  if (deExpressionGetType(call) != DE_EXPR_CALL) {
    deError(line, "Expecting call to iterator here");
  }
  deSignature signature = deExpressionGetSignature(call);
  utAssert(signature != deSignatureNull);
  deFunction iterator;
  iterator = deSignatureGetUniquifiedFunction(signature);
  if (deFunctionGetType(iterator) != DE_FUNC_ITERATOR) {
    deError(line, "Expecting call to iterator here");
  }
  deBlock block = deStatementGetBlock(statement);
  deStatement prevStatement = deStatementGetPrevBlockStatement(statement);
  deBlock iteratorBlock = deFunctionGetSubBlock(iterator);
  deExpression iteratorAccess = deExpressionGetFirstExpression(call);
  deExpression parameters = deExpressionGetNextExpression(iteratorAccess);
  deStatement lastStatement = deStatementGetNextBlockStatement(statement);
  bool isMethodCall = deExpressionIsMethodCall(iteratorAccess);
  deResolveBlockVariableNameConfligts(iteratorBlock, scopeBlock);
  deStatement lastAssignState = assignIteratorParameters(
      statement, iteratorBlock, parameters, isMethodCall);
  if (isMethodCall) {
    deExpression selfAccess = deExpressionGetFirstExpression(iteratorAccess);
    deVariable selfVar = deBlockGetFirstVariable(iteratorBlock);
    lastAssignState = assignVariable(lastAssignState, selfVar, selfAccess);
  }
  deCopyBlockStatementsAfterStatement(iteratorBlock, lastAssignState);
  deStatement firstStatement = deStatementGetNextBlockStatement(statement);
  deBlock body = deStatementGetSubBlock(statement);
  deStatementRemoveSubBlock(statement, body);
  deStatement yieldStatement = findYieldStatement(firstStatement, lastStatement);
  turnYieldIntLoopVarAssignment(yieldStatement, assignment);
  deStatementDestroy(statement);
  // Insert body after the yield statement, which is now the loop var assignment.
  deMoveBlockStatementsAfterStatement(body, yieldStatement);
  deBlockDestroy(body);
  flattenSwitchTypeStatements(firstStatement, lastStatement);
  if (firstStatement != deStatementNull) {
    queueStatements(firstStatement, lastStatement);
    deBindAllSignatures();
  }
  deRestoreBlockVariableNames(iteratorBlock);
  if (prevStatement == deStatementNull) {
    return deBlockGetFirstStatement(block);
  }
  deInIterator = savedInIterator;
  return deStatementGetNextBlockStatement(prevStatement);
}

// Inline iterators in the block.  Return true if any iterators were inlined.
static void inlineBlockIterators(deBlock scopeBlock, deBlock block) {
  bool inlinedIterator;
  deStatement statement;
  do {
    inlinedIterator = false;
    deSafeForeachBlockStatement(block, statement) {
      if (deStatementGetType(statement) == DE_STATEMENT_FOREACH &&
          deStatementInstantiated(statement)) {
        deInlineIterator(scopeBlock, statement);
        inlinedIterator = true;
      }
    } deEndSafeBlockStatement;
  } while (inlinedIterator);
  deSafeForeachBlockStatement(block, statement) {
    deBlock subBlock = deStatementGetSubBlock(statement);
    if (subBlock != deBlockNull) {
      inlineBlockIterators(scopeBlock, subBlock);
    }
  } deEndSafeBlockStatement;
}

// Inline iterators.
void deInlineIterators(void) {
  deSignature signature;
  deForeachRootSignature(deTheRoot, signature) {
    if (deSignatureInstantiated(signature)) {
      deBlock block = deSignatureGetBlock(signature);
      // TODO: Pass signature as an  argument when we removed the old binder.
      deCurrentSignature = signature;
      inlineBlockIterators(block, block);
    }
  } deEndRootSignature;
}

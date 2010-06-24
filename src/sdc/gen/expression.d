/**
 * Copyright 2010 Bernard Helyer
 * This file is part of SDC. SDC is licensed under the GPL.
 * See LICENCE or sdc.d for more details.
 */
module sdc.gen.expression;

import std.stdio;
import std.string;

import sdc.primitive;
import sdc.compilererror;
import sdc.ast.all;
import sdc.extract.base;
import sdc.extract.expression;
import sdc.gen.base;
import sdc.gen.semantic;

Variable genExpression(Expression expression, File file, Semantic semantic)
{
    return genAssignExpression(expression.assignExpression, file, semantic);
}

Variable genAssignExpression(AssignExpression expression, File file, Semantic semantic)
{
    return genConditionalExpression(expression.conditionalExpression, file, semantic);
}

Variable genConditionalExpression(ConditionalExpression expression, File file, Semantic semantic)
{
    return genOrOrExpression(expression.orOrExpression, file, semantic);
}

Variable genOrOrExpression(OrOrExpression expression, File file, Semantic semantic)
{
    return genAndAndExpression(expression.andAndExpression, file, semantic);
}

Variable genAndAndExpression(AndAndExpression expression, File file, Semantic semantic)
{
    return genOrExpression(expression.orExpression, file, semantic);
}

Variable genOrExpression(OrExpression expression, File file, Semantic semantic)
{
    return genXorExpression(expression.xorExpression, file, semantic);
}

Variable genXorExpression(XorExpression expression, File file, Semantic semantic)
{
    return genAndExpression(expression.andExpression, file, semantic);
}

Variable genAndExpression(AndExpression expression, File file, Semantic semantic)
{
    return genCmpExpression(expression.cmpExpression, file, semantic);
}

Variable genCmpExpression(CmpExpression expression, File file, Semantic semantic)
{
    return genShiftExpression(expression.lhShiftExpression, file, semantic);
}

Variable genShiftExpression(ShiftExpression expression, File file, Semantic semantic)
{
    return genAddExpression(expression.addExpression, file, semantic);
}

Variable genAddExpression(AddExpression expression, File file, Semantic semantic)
{
    auto var = genMulExpression(expression.mulExpression, file, semantic);
    if (expression.addExpression !is null) {
        auto var2 = genAddExpression(expression.addExpression, file, semantic);
        
        Variable result;
        if (expression.addOperation == AddOperation.Add) {
            result = asmgen.emitAddOps(file, var, var2);
        } else {
            result = asmgen.emitSubOps(file, var, var2);
        }
        return result;
    }
    return var;
}

Variable genMulExpression(MulExpression expression, File file, Semantic semantic)
{
    auto var = genPowExpression(expression.powExpression, file, semantic);
    if (expression.mulExpression !is null) {
        auto var2 = genMulExpression(expression.mulExpression, file, semantic);
        
        Variable result;
        if (expression.mulOperation == MulOperation.Mul) {
            result = asmgen.emitMulOps(file, var, var2);
        } else {
            result = asmgen.emitDivOps(file, var, var2);
        }
        return result;
    }
    return var;
}

Variable genPowExpression(PowExpression expression, File file, Semantic semantic)
{
    return genUnaryExpression(expression.unaryExpression, file, semantic);
}

Variable genUnaryExpression(UnaryExpression expression, File file, Semantic semantic)
{
    if (expression.unaryPrefix != UnaryPrefix.None) {
        auto var = genUnaryExpression(expression.unaryExpression, file, semantic);
        if (expression.unaryPrefix == UnaryPrefix.UnaryMinus) {
            var = asmgen.emitNeg(file, var);
        }
        return var;
    }
    return genPostfixExpression(expression.postfixExpression, file, semantic);
}

Variable genPostfixExpression(PostfixExpression expression, File file, Semantic semantic)
{
    auto var = genPrimaryExpression(expression.primaryExpression, file, semantic);
    
    if (expression.postfixOperation == PostfixOperation.Parens) {
        Variable[] args;
        foreach (argument; expression.argumentList.expressions) {
            args ~= genAssignExpression(argument, file, semantic);
        }
        return asmgen.emitFunctionCall(file, var, args);
    }
    
    return var;
}

Variable genPrimaryExpression(PrimaryExpression expression, File file, Semantic semantic)
{
    Variable var;
    
    switch (expression.type) {
    case PrimaryType.Identifier:
        return genIdentifierExpression(cast(Identifier) expression.node, file, semantic);
    case PrimaryType.IntegerLiteral:
        var = genVariable(Primitive(32, 0), "primitive");
        var.dType = PrimitiveTypeType.Int;
        asmgen.emitAlloca(file, var);
        asmgen.emitStore(file, var, new Constant((cast(IntegerLiteral)expression.node).value, Primitive(32, 0)));
        break;
    case PrimaryType.True:
        var = genVariable(Primitive(8, 0), "true");
        var.dType = PrimitiveTypeType.Bool;
        asmgen.emitAlloca(file, var);
        asmgen.emitStore(file, var, new Constant("1", Primitive(8, 0)));
        break;
    case PrimaryType.False:
        var = genVariable(Primitive(8, 0), "false");
        var.dType = PrimitiveTypeType.Bool;
        asmgen.emitAlloca(file, var);
        asmgen.emitStore(file, var, new Constant("0", Primitive(8, 0)));
        break;
    default:
        break;
    }
    
    return var;
}


Variable genIdentifierExpression(Identifier identifier, File file, Semantic semantic)
{
        string ident = extractIdentifier(identifier);
        auto decl = semantic.findDeclaration(ident);
        if (decl is null) {
            error(identifier.location, format("undefined identifier '%s'", ident));
        }
        
        Variable var;
        switch (decl.dtype) {
        case DeclType.SyntheticVariable:
            auto syn = cast(SyntheticVariableDeclaration) decl;
            var = genVariable(fullTypeToPrimitive(syn.type), extractIdentifier(syn.identifier));
            var.dType = PrimitiveTypeType.Int;  // !!!
            asmgen.emitAlloca(file, var);
            if (syn.isParameter) {
                asmgen.emitStore(file, var, new Variable(extractIdentifier(syn.identifier), fullTypeToPrimitive(syn.type)));
            }
            break;
        case DeclType.Function:
            auto fun = cast(FunctionDeclaration) decl;
            auto prim = fullTypeToPrimitive(fun.retval);
            auto name = extractIdentifier(fun.name);
            var = new Variable(name, prim);
            break;
        default:
            error(identifier.location, "unknown declaration type");
        }
        
        return var;
}

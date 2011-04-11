/**
 * Copyright 2010 Bernard Helyer.
 * This file is part of SDC. SDC is licensed under the GPL.
 * See LICENCE or sdc.d for more details.
 */
module sdc.gen.base;

import std.array;
import std.algorithm;
import std.conv;
import std.exception;
import std.string;

import sdc.compilererror;
import sdc.util;
import sdc.extract;
import sdc.global;
import ast = sdc.ast.all;
import sdc.gen.sdcmodule;
import sdc.gen.sdcimport;
import sdc.gen.sdcclass;
import sdc.gen.declaration;
import sdc.gen.expression;
import sdc.gen.type;
import sdc.gen.aggregate;
import sdc.gen.attribute;
import sdc.gen.enumeration;
import sdc.gen.sdctemplate;


bool canGenDeclarationDefinition(ast.DeclarationDefinition declDef, Module mod)
{
    switch (declDef.type) with (ast) {
    case DeclarationDefinitionType.Declaration:
        return canGenDeclaration(cast(Declaration) declDef.node, mod);
    case DeclarationDefinitionType.ImportDeclaration:
        return canGenImportDeclaration(cast(ImportDeclaration) declDef.node, mod);
    case ast.DeclarationDefinitionType.ConditionalDeclaration:
        return true;  // TODO
    case ast.DeclarationDefinitionType.AggregateDeclaration:
        return canGenAggregateDeclaration(cast(ast.AggregateDeclaration) declDef.node, mod);
    case ast.DeclarationDefinitionType.AttributeSpecifier:
        return canGenAttributeSpecifier(cast(ast.AttributeSpecifier) declDef.node, mod);
    case ast.DeclarationDefinitionType.TemplateDeclaration:
        return true;  // TODO
    case ast.DeclarationDefinitionType.ClassDeclaration:
        return canGenClassDeclaration(cast(ast.ClassDeclaration) declDef.node, mod);
    case ast.DeclarationDefinitionType.EnumDeclaration:
        return true;  // TODO
    default:
        return false;
    }
    assert(false);
}

Module genModule(ast.Module astModule)
{
    auto mod = new Module(astModule.moduleDeclaration.name);
    genModuleAndPackages(mod);

    auto name = extractQualifiedName(mod.name);
    verbosePrint("Generating module '" ~ name ~ "'.", VerbosePrintColour.Red);
    verboseIndent++;

    resolveDeclarationDefinitionList(astModule.declarationDefinitions, mod, null);

    verboseIndent--;
    verbosePrint("Done generating '" ~ name ~ "'.", VerbosePrintColour.Red);

    return mod;
}

void genModuleAndPackages(Module mod)
{
    Scope parentScope = mod.currentScope;
    foreach (i, identifier; mod.name.identifiers) {
        if (i < mod.name.identifiers.length - 1) {
            // Package.
            auto name = extractIdentifier(identifier);
            auto _scope = new Scope();
            parentScope.add(name, new Store(_scope));
            parentScope = _scope;
        } else {
            // Module.
            auto name = extractIdentifier(identifier);
            auto store = new Store(mod.currentScope);
            parentScope.add(name, store);
        }
    }
}

void resolveDeclarationDefinitionList(ast.DeclarationDefinition[] list, Module mod, Type parentType)
{
    auto resolutionList = list.dup;
    size_t tmp, oldStillToGo;
    size_t* stillToGo; 
    if (parentType is null) {
        stillToGo = &tmp;
    } else {
        stillToGo = &parentType.stillToGo;
    }
    assert(stillToGo);

    foreach (d; resolutionList) {
        d.parentName = mod.name;
        d.importedSymbol = false;
        d.buildStage = ast.BuildStage.Unhandled;
    }
    bool finalPass;
    do {
        foreach (declDef; resolutionList) {
            declDef.parentType = parentType;
            genDeclarationDefinition(declDef, mod);
        }
        
        *stillToGo = count!"a.buildStage < b"(resolutionList, ast.BuildStage.ReadyForCodegen);
        
        // Let's figure out if we can leave.
        if (*stillToGo == 0) {
            break;
        } else if (*stillToGo == oldStillToGo) {
            // Uh-oh.. nothing new was resolved... look for things we can expand.
            ast.DeclarationDefinition[] toAppend;
            foreach (declDef; resolutionList) {
                if (declDef.buildStage == ast.BuildStage.ReadyToExpand) {
                    toAppend ~= expand(declDef, mod);
                }
                foreach (d; toAppend) if (d.buildStage != ast.BuildStage.DoneForever) {
                    d.buildStage = ast.BuildStage.Unhandled;
                }
            }
            if (toAppend.length > 0) {
                resolutionList ~= toAppend;
            } else {
                if (!finalPass) {
                    finalPass = true;
                    continue;
                }
                // Module compilation failed.
                if (mod.lookupFailures.length > 0) {
                    auto failure = mod.lookupFailures[$ - 1];
                    throw new CompilerError(failure.location, format("type '%s' is undefined.", failure.name));
                } else {
                    throw new CompilerPanic("module compilation failure.");
                }
            }
        }
        oldStillToGo = *stillToGo;
    } while (true);
}

ast.DeclarationDefinition[] expand(ast.DeclarationDefinition declDef, Module mod)
{
    declDef.buildStage = ast.BuildStage.Done;
    switch (declDef.type) {
    case ast.DeclarationDefinitionType.AttributeSpecifier: 
        auto specifier = cast(ast.AttributeSpecifier) declDef.node;
        assert(specifier);
        if (specifier.declarationBlock is null) {
            throw new CompilerPanic(declDef.location, "attempted to expand non declaration block containing attribute specifier.");
        }
        //genAttributeSpecifier(specifier, mod);
        auto list = specifier.declarationBlock.declarationDefinitions.dup;
        foreach (e; list) {
            e.attributes ~= specifier.attribute;
        }
        return list;
    case ast.DeclarationDefinitionType.ConditionalDeclaration:
        auto decl = enforce(cast(ast.ConditionalDeclaration) declDef.node);
        bool cond = genCondition(decl.condition, mod);
        ast.DeclarationDefinition[] newTopLevels;
        if (cond) {
            foreach (declDef_; decl.thenBlock.declarationDefinitions) {
                newTopLevels ~= declDef_;
            }
        } else if (decl.elseBlock !is null) {
            foreach (declDef_; decl.elseBlock.declarationDefinitions) {
                newTopLevels ~= declDef_;
            }
        }
        return newTopLevels;
    default:
        throw new CompilerPanic(declDef.location, "attempted to expand non expandable declaration definition.");
    }
    assert(false);
}

void genDeclarationDefinition(ast.DeclarationDefinition declDef, Module mod)
{
    with (declDef) with (ast.BuildStage)
    if (buildStage != Unhandled && buildStage != Deferred) {
        return;
    }
    
    mixin(saveAttributeString);
    
    foreach (attribute; declDef.attributes) {
        mixin(handleAttributeString);
    }
    
    switch (declDef.type) {
    case ast.DeclarationDefinitionType.Declaration:
        auto decl = cast(ast.Declaration) declDef.node;
        assert(decl);
        auto can = canGenDeclaration(decl, mod);        
        if (can) {
            if (decl.type != ast.DeclarationType.Function) {
                declareDeclaration(decl, declDef, mod);
                genDeclaration(decl, declDef, mod);
                declDef.buildStage = ast.BuildStage.Done;
            } else {
                declareDeclaration(decl, declDef, mod);
                declDef.buildStage = ast.BuildStage.ReadyForCodegen;
                mod.functionBuildList ~= declDef;
            }
        } else {
            declDef.buildStage = ast.BuildStage.Deferred;
        }
        break;
    case ast.DeclarationDefinitionType.ImportDeclaration:
        declDef.buildStage = ast.BuildStage.Done;
        genImportDeclaration(cast(ast.ImportDeclaration) declDef.node, mod);
        break;
    case ast.DeclarationDefinitionType.AggregateDeclaration:
        auto can = canGenAggregateDeclaration(cast(ast.AggregateDeclaration) declDef.node, mod);
        if (can) {
            genAggregateDeclaration(cast(ast.AggregateDeclaration) declDef.node, declDef, mod);
            declDef.buildStage = ast.BuildStage.Done;
        } else {
            declDef.buildStage = ast.BuildStage.Deferred;
        }
        break;
    case ast.DeclarationDefinitionType.ClassDeclaration:
        genClassDeclaration(cast(ast.ClassDeclaration) declDef.node, mod);
        declDef.buildStage = ast.BuildStage.Done;
        break;
    case ast.DeclarationDefinitionType.AttributeSpecifier:
        auto can = canGenAttributeSpecifier(cast(ast.AttributeSpecifier) declDef.node, mod);
        if (can) {
            declDef.buildStage = ast.BuildStage.ReadyToExpand;
        } else {
            declDef.buildStage = ast.BuildStage.Deferred;
        }
        break;
    case ast.DeclarationDefinitionType.ConditionalDeclaration:
        genConditionalDeclaration(declDef, cast(ast.ConditionalDeclaration) declDef.node, mod);
        break;
    case ast.DeclarationDefinitionType.EnumDeclaration:
        genEnumDeclaration(cast(ast.EnumDeclaration) declDef.node, mod);
        declDef.buildStage = ast.BuildStage.Done;
        break;
    case ast.DeclarationDefinitionType.TemplateDeclaration:
        genTemplateDeclaration(cast(ast.TemplateDeclaration) declDef.node, mod);
        declDef.buildStage = ast.BuildStage.Done;
        break;
    default:
        throw new CompilerPanic(declDef.location, format("unhandled DeclarationDefinition '%s'", to!string(declDef.type)));
    }
    
    mixin(restoreAttributeString);
}


void genConditionalDeclaration(ast.DeclarationDefinition declDef, ast.ConditionalDeclaration decl, Module mod)
{
    final switch (decl.type) {
    case ast.ConditionalDeclarationType.Block:    
        declDef.buildStage = ast.BuildStage.ReadyToExpand;
        break;
    case ast.ConditionalDeclarationType.VersionSpecification:        
        declDef.buildStage = ast.BuildStage.Done;
        auto spec = cast(ast.VersionSpecification) decl.specification;
        auto ident = extractIdentifier(cast(ast.Identifier) spec.node);
        if (mod.hasVersionBeenTested(ident)) {
            throw new CompilerError(spec.location, format("specification of '%s' after use is not allowed.", ident));
        }
        mod.setVersion(decl.location, ident);
        break;
    case ast.ConditionalDeclarationType.DebugSpecification:
        declDef.buildStage = ast.BuildStage.Done;
        auto spec = cast(ast.DebugSpecification) decl.specification;
        auto ident = extractIdentifier(cast(ast.Identifier) spec.node);
        if (mod.hasDebugBeenTested(ident)) {
            throw new CompilerError(spec.location, format("specification of '%s' after use is not allowed.", ident));
        }
        mod.setDebug(decl.location, ident);
        break;
    }
}

bool genCondition(ast.Condition condition, Module mod)
{
    final switch (condition.conditionType) {
    case ast.ConditionType.Version:
        return genVersionCondition(cast(ast.VersionCondition) condition.condition, mod);
    case ast.ConditionType.Debug:
        return genDebugCondition(cast(ast.DebugCondition) condition.condition, mod);
    case ast.ConditionType.StaticIf:
        return genStaticIfCondition(cast(ast.StaticIfCondition) condition.condition, mod);
    }
}

bool genVersionCondition(ast.VersionCondition condition, Module mod)
{
    final switch (condition.type) {
    case ast.VersionConditionType.Identifier:
        auto ident = extractIdentifier(condition.identifier);
        return mod.isVersionSet(ident);
    case ast.VersionConditionType.Unittest:
        return unittestsEnabled;
    }
}

bool genDebugCondition(ast.DebugCondition condition, Module mod)
{
    final switch (condition.type) {
    case ast.DebugConditionType.Simple:
        return isDebug;
    case ast.DebugConditionType.Identifier:
        auto ident = extractIdentifier(condition.identifier);
        return mod.isDebugSet(ident);
    }
}

bool genStaticIfCondition(ast.StaticIfCondition condition, Module mod)
{
    auto expr = genAssignExpression(condition.expression, mod);
    if (!expr.isKnown) {
        throw new CompilerError(condition.expression.location, "expression inside of a static if must be known at compile time.");
    }
    return expr.knownBool;
}


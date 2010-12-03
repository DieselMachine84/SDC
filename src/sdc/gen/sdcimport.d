/**
 * Copyright 2010 Bernard Helyer.
 * Copyright 2010 Jakob Ovrum.
 * This file is part of SDC. SDC is licensed under the GPL.
 * See LICENCE or sdc.d for more details.
 */
module sdc.gen.sdcimport;

import std.string;
import file = std.file;
import path = std.path;

import sdc.util;
import sdc.compilererror;
import sdc.location;
import sdc.global;
import sdc.source;
import sdc.lexer;
import sdc.extract.base;
import ast = sdc.ast.all;
import parser = sdc.parser.all;
import sdc.gen.base;
import sdc.gen.sdcmodule;


bool canGenImportDeclaration(ast.ImportDeclaration importDeclaration, Module mod)
{
    return true;
}

ast.ImportDeclaration synthesiseImport(string modname)
{
    with (ast) {
        auto decl = new ImportDeclaration();
        decl.importList = new ImportList();
        decl.importList.type = ImportListType.SingleSimple;
        auto imp = new Import();
        
        auto names = split(modname, ".");
        auto qname = new QualifiedName();
        foreach (name; names) {
            auto iname = new Identifier();
            iname.value = name;
            qname.identifiers ~= iname;
        }
        imp.moduleName = qname;
        decl.importList.imports ~= imp;
        return decl;
    }
} 

void genImportDeclaration(ast.ImportDeclaration importDeclaration, Module mod)
{
    return genImportList(importDeclaration.location, importDeclaration.importList, mod);
}

void genImportList(Location loc, ast.ImportList importList, Module mod)
{
    final switch (importList.type) {
    case ast.ImportListType.SingleSimple:
        foreach (imp; importList.imports) {
            genImport(loc, imp, mod);
        }
        break;
    case ast.ImportListType.SingleBinder:
        throw new CompilerPanic(importList.location, "TODO: single binder import list.");
    case ast.ImportListType.Multiple:
        throw new CompilerPanic(importList.location, "TODO: multiple import list.");
    }
}

void genImportBinder(ast.ImportBinder importBinder, Module mod)
{
}

void genImportBind(ast.ImportBind importBind, Module mod)
{
}

private string searchImport(string impPath)
{
    if (file.exists(impPath) && file.isfile(impPath)) {
        return impPath;
    } else {
        auto impInterfacePath = impPath ~ 'i';
        if (file.exists(impInterfacePath) && file.isfile(impInterfacePath)) {
            return impInterfacePath;
        }
    }
    
    foreach (importPath; importPaths) {
        auto fullPath = importPath ~ path.sep ~ impPath;
        if (file.exists(fullPath) && file.isfile(fullPath)) {
            return fullPath;
        }
        
        fullPath ~= 'i';
        
        if (file.exists(fullPath) && file.isfile(fullPath)) {
            return fullPath;
        }
    }
    return null;
}

void genImport(Location location, ast.Import theImport, Module mod)
{
    auto name = extractQualifiedName(theImport.moduleName);
    auto tu = getTranslationUnit(name);
    if (tu !is null) {
        if (!mod.importedTranslationUnits.contains(tu)) {
            mod.importedTranslationUnits ~= tu;
        }
        return;
    }

    auto impPath = extractModulePath(theImport.moduleName);
    auto fullPath = searchImport(impPath);
    if (fullPath is null) {
        auto err = new CompilerError(
            theImport.moduleName.location,
            format(`module "%s" could not be found.`, name),
            new CompilerError(format(`tried path "%s"`, impPath))
        );
        
        auto next = err.more;
        foreach (importPath; importPaths) {
            next = next.more = new CompilerError(
                format(`tried path "%s"`, importPath ~ path.sep ~ impPath)
            );
        }
        throw err;
    }
    
    tu = new TranslationUnit();
    tu.tusource = TUSource.Import;
    tu.compile = false;
    tu.filename = fullPath;
    tu.source = new Source(fullPath);
    tu.tstream = lex(tu.source);
    tu.aModule = parser.parseModule(tu.tstream);
    
    auto moduleDecl = extractQualifiedName(tu.aModule.moduleDeclaration.name);
    if (moduleDecl != name) {
        throw new CompilerError(
            theImport.moduleName.location,
            `name of imported module does not match import directive.`,
            new CompilerError(
                tu.aModule.moduleDeclaration.name.location,
                `module declaration:`
            )
        );
    }
    
    addTranslationUnit(name, tu);
    mod.importedTranslationUnits ~= tu;
    
    tu.gModule = genModule(tu.aModule);
}

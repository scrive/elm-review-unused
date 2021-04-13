module NoUnused.Dependencies exposing (rule)

{-| Forbid the use of dependencies that are never used in your project.


# Rule

@docs rule

-}

import Dict exposing (Dict)
import Elm.Constraint
import Elm.Package
import Elm.Project exposing (Project)
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Range exposing (Range)
import Elm.Version
import Review.Project.Dependency as Dependency exposing (Dependency)
import Review.Rule as Rule exposing (Error, Rule)
import Set exposing (Set)


{-| Forbid the use of dependencies that are never used in your project.

A dependency is considered unused if none of its modules are imported in the project.

    config =
        [ NoUnused.Dependencies.rule
        ]


## Try it out

You can try this rule out by running the following command:

```bash
elm-review --template jfmengels/elm-elm-review-unused/example --rules NoUnused.Dependencies
```

-}
rule : Rule
rule =
    Rule.newProjectRuleSchema "NoUnused.Dependencies" initialProjectContext
        |> Rule.withElmJsonProjectVisitor elmJsonVisitor
        |> Rule.withDependenciesProjectVisitor dependenciesVisitor
        |> Rule.withModuleVisitor moduleVisitor
        |> Rule.withModuleContextUsingContextCreator
            { fromProjectToModule = fromProjectToModule
            , fromModuleToProject = fromModuleToProject
            , foldProjectContexts = foldProjectContexts
            }
        |> Rule.withFinalProjectEvaluation finalEvaluationForProject
        |> Rule.fromProjectRuleSchema


moduleVisitor : Rule.ModuleRuleSchema {} ModuleContext -> Rule.ModuleRuleSchema { hasAtLeastOneVisitor : () } ModuleContext
moduleVisitor schema =
    schema
        |> Rule.withImportVisitor importVisitor


dependenciesVisitor : Dict String Dependency -> ProjectContext -> ( List nothing, ProjectContext )
dependenciesVisitor dependencies projectContext =
    let
        moduleNameToDependency : Dict String String
        moduleNameToDependency =
            dependencies
                |> Dict.toList
                |> List.concatMap
                    (\( packageName, dependency ) ->
                        List.map (\{ name } -> ( name, packageName )) (Dependency.modules dependency)
                    )
                |> Dict.fromList
    in
    ( []
    , { projectContext
        | dependencies = dependencies
        , moduleNameToDependency = moduleNameToDependency
      }
    )



-- CONTEXT


type alias ProjectContext =
    { moduleNameToDependency : Dict String String
    , dependencies : Dict String Dependency
    , directProjectDependencies : Set String
    , directTestDependencies : Set String
    , usedDependencies : Set String
    , usedDependenciesFromTest : Set String
    , elmJsonKey : Maybe Rule.ElmJsonKey
    }


type alias ModuleContext =
    { moduleNameToDependency : Dict String String
    , usedDependencies : Set String
    }


initialProjectContext : ProjectContext
initialProjectContext =
    { moduleNameToDependency = Dict.empty
    , dependencies = Dict.empty
    , directProjectDependencies = Set.empty
    , directTestDependencies = Set.empty
    , usedDependencies = Set.empty
    , usedDependenciesFromTest = Set.empty
    , elmJsonKey = Nothing
    }


fromProjectToModule : Rule.ContextCreator ProjectContext ModuleContext
fromProjectToModule =
    Rule.initContextCreator
        (\projectContext ->
            { moduleNameToDependency = projectContext.moduleNameToDependency
            , usedDependencies = Set.empty
            }
        )


fromModuleToProject : Rule.ContextCreator ModuleContext ProjectContext
fromModuleToProject =
    Rule.initContextCreator
        (\metadata { usedDependencies } ->
            let
                isSourceDir : Bool
                isSourceDir =
                    Rule.isInSourceDirectories metadata
            in
            { moduleNameToDependency = Dict.empty
            , dependencies = Dict.empty
            , directProjectDependencies = Set.empty
            , directTestDependencies = Set.empty
            , usedDependencies =
                if isSourceDir then
                    usedDependencies

                else
                    Set.empty
            , usedDependenciesFromTest =
                if isSourceDir then
                    Set.empty

                else
                    usedDependencies
            , elmJsonKey = Nothing
            }
        )
        |> Rule.withMetadata


foldProjectContexts : ProjectContext -> ProjectContext -> ProjectContext
foldProjectContexts newContext previousContext =
    { moduleNameToDependency = previousContext.moduleNameToDependency
    , dependencies = previousContext.dependencies
    , directProjectDependencies = previousContext.directProjectDependencies
    , directTestDependencies = previousContext.directTestDependencies
    , usedDependencies = Set.union newContext.usedDependencies previousContext.usedDependencies
    , usedDependenciesFromTest = Set.union newContext.usedDependenciesFromTest previousContext.usedDependenciesFromTest
    , elmJsonKey = previousContext.elmJsonKey
    }



-- PROJECT VISITORS


elmJsonVisitor : Maybe { elmJsonKey : Rule.ElmJsonKey, project : Project } -> ProjectContext -> ( List nothing, ProjectContext )
elmJsonVisitor maybeProject projectContext =
    case maybeProject of
        Just { elmJsonKey, project } ->
            let
                ( directProjectDependencies, directTestDependencies ) =
                    case project of
                        Elm.Project.Package { deps, testDeps } ->
                            ( deps
                                |> List.map (Tuple.first >> Elm.Package.toString)
                                |> Set.fromList
                            , testDeps
                                |> List.map (Tuple.first >> Elm.Package.toString)
                                |> Set.fromList
                            )

                        Elm.Project.Application { depsDirect, testDepsDirect } ->
                            ( depsDirect
                                |> List.map (Tuple.first >> Elm.Package.toString)
                                |> Set.fromList
                            , testDepsDirect
                                |> List.map (Tuple.first >> Elm.Package.toString)
                                |> Set.fromList
                            )
            in
            ( []
            , { projectContext
                | elmJsonKey = Just elmJsonKey
                , directProjectDependencies = directProjectDependencies
                , directTestDependencies = directTestDependencies
              }
            )

        Nothing ->
            ( [], projectContext )



-- IMPORT VISITOR


importVisitor : Node Import -> ModuleContext -> ( List nothing, ModuleContext )
importVisitor node context =
    ( []
    , case Dict.get (moduleNameForImport node) context.moduleNameToDependency of
        Just dependency ->
            { context | usedDependencies = Set.insert dependency context.usedDependencies }

        Nothing ->
            context
    )


moduleNameForImport : Node Import -> String
moduleNameForImport node =
    node
        |> Node.value
        |> .moduleName
        |> Node.value
        |> String.join "."



-- FINAL EVALUATION


finalEvaluationForProject : ProjectContext -> List (Error { useErrorForModule : () })
finalEvaluationForProject projectContext =
    case projectContext.elmJsonKey of
        Just elmJsonKey ->
            let
                depsNotUsedInSrc : Set String
                depsNotUsedInSrc =
                    Set.diff projectContext.directProjectDependencies projectContext.usedDependencies

                depsNotUsedInSrcButUsedInTests : Set String
                depsNotUsedInSrcButUsedInTests =
                    Set.intersect depsNotUsedInSrc projectContext.usedDependenciesFromTest
                        |> Set.remove "elm/core"

                depsNotUsedInSrcErrors : List String
                depsNotUsedInSrcErrors =
                    Set.diff depsNotUsedInSrc depsNotUsedInSrcButUsedInTests
                        |> Set.remove "elm/core"
                        |> Set.toList

                testDepsNotUsedInTests : List String
                testDepsNotUsedInTests =
                    Set.diff projectContext.directTestDependencies projectContext.usedDependenciesFromTest
                        |> Set.remove "elm/core"
                        |> Set.toList
            in
            List.map (error elmJsonKey projectContext.dependencies) depsNotUsedInSrcErrors
                ++ List.map (testError elmJsonKey) testDepsNotUsedInTests
                ++ List.map (onlyTestDependencyError elmJsonKey projectContext.dependencies) (Set.toList depsNotUsedInSrcButUsedInTests)

        Nothing ->
            []


error : Rule.ElmJsonKey -> Dict String Dependency -> String -> Error scope
error elmJsonKey dependencies packageNameStr =
    Rule.errorForElmJsonWithFix elmJsonKey
        (\elmJson ->
            { message = "Unused dependency `" ++ packageNameStr ++ "`"
            , details =
                [ "To remove it, I recommend running the following command:"
                , "    elm-json uninstall " ++ packageNameStr
                ]
            , range = findPackageNameInElmJson packageNameStr elmJson
            }
        )
        (\project ->
            case project of
                Elm.Project.Application application ->
                    case find (isPackageWithName packageNameStr) application.depsDirect of
                        Just ( packageName, version ) ->
                            Elm.Project.Application
                                { application
                                    | depsDirect = List.filter (isPackageWithName packageNameStr >> not) application.depsDirect
                                    , depsIndirect =
                                        if isADependencyOfAnotherDependency packageName application.depsDirect dependencies then
                                            ( packageName, version ) :: application.depsIndirect

                                        else
                                            application.depsIndirect
                                }
                                |> Just

                        Nothing ->
                            Nothing

                Elm.Project.Package packageInfo ->
                    Elm.Project.Package
                        { packageInfo
                            | deps = List.filter (isPackageWithName packageNameStr >> not) packageInfo.deps
                        }
                        |> Just
        )


type ProjectAndDependencyIdentifier
    = ApplicationProject { project : Elm.Project.ApplicationInfo, name : Elm.Package.Name, version : Elm.Version.Version }
    | PackageProject { project : Elm.Project.PackageInfo, name : Elm.Package.Name, constraint : Elm.Constraint.Constraint }


fromProject : Project -> String -> Maybe ProjectAndDependencyIdentifier
fromProject project packageNameStr =
    case project of
        Elm.Project.Application application ->
            -- TODO Make it possible to look at test dependencies
            case find (isPackageWithName packageNameStr) application.depsDirect of
                Just ( packageName, version ) ->
                    Just (ApplicationProject { project = application, name = packageName, version = version })

                Nothing ->
                    Nothing

        Elm.Project.Package packageInfo ->
            -- TODO Make it possible to look at test dependencies
            case find (isPackageWithName packageNameStr) packageInfo.deps of
                Just ( packageName, constraint ) ->
                    Just (PackageProject { project = packageInfo, name = packageName, constraint = constraint })

                Nothing ->
                    Nothing


toProject : ProjectAndDependencyIdentifier -> Elm.Project.Project
toProject projectAndDependencyIdentifier =
    case projectAndDependencyIdentifier of
        ApplicationProject { project } ->
            Elm.Project.Application project

        PackageProject { project } ->
            Elm.Project.Package project


removeProjectDependency2 : Dict String Dependency -> ProjectAndDependencyIdentifier -> ProjectAndDependencyIdentifier
removeProjectDependency2 dependencies projectAndDependencyIdentifier =
    case projectAndDependencyIdentifier of
        ApplicationProject ({ project } as application) ->
            ApplicationProject
                { application
                    | project =
                        { project
                            | depsDirect = List.filter (isPackageWithName (Elm.Package.toString application.name) >> not) project.depsDirect
                            , depsIndirect =
                                if isADependencyOfAnotherDependency application.name (project.depsDirect ++ project.depsIndirect) dependencies then
                                    ( application.name, application.version ) :: project.depsIndirect

                                else
                                    project.depsIndirect
                        }
                }

        PackageProject ({ project } as package) ->
            PackageProject
                { package
                    | project =
                        { project
                            | deps = List.filter (isPackageWithName (Elm.Package.toString package.name) >> not) project.deps
                        }
                }


removeProjectDependency : Dict String Dependency -> String -> Project -> Project
removeProjectDependency dependencies packageNameStr project =
    case project of
        Elm.Project.Application application ->
            case find (isPackageWithName packageNameStr) application.depsDirect of
                Just ( packageName, version ) ->
                    Elm.Project.Application
                        { application
                            | depsDirect = List.filter (isPackageWithName packageNameStr >> not) application.depsDirect
                            , depsIndirect =
                                if isADependencyOfAnotherDependency packageName (application.depsDirect ++ application.depsIndirect) dependencies then
                                    ( packageName, version ) :: application.depsIndirect

                                else
                                    application.depsIndirect
                        }

                Nothing ->
                    project

        Elm.Project.Package packageInfo ->
            Elm.Project.Package
                { packageInfo
                    | deps = List.filter (isPackageWithName packageNameStr >> not) packageInfo.deps
                }


removeTestDependency : String -> Project -> Project
removeTestDependency packageName project =
    case project of
        Elm.Project.Application application ->
            Elm.Project.Application
                { application
                    | testDepsDirect = List.filter (isPackageWithName packageName >> not) application.testDepsDirect
                }

        Elm.Project.Package packageInfo ->
            Elm.Project.Package
                { packageInfo
                    | testDeps = List.filter (isPackageWithName packageName >> not) packageInfo.testDeps
                }


addTestDependency : String -> Project -> Project
addTestDependency packageName project =
    case project of
        Elm.Project.Application application ->
            case find (isPackageWithName packageName) application.depsDirect of
                Just packageDep ->
                    Elm.Project.Application
                        { application
                            | depsDirect = List.filter (isPackageWithName packageName >> not) application.depsDirect
                            , testDepsDirect = packageDep :: application.testDepsDirect
                        }

                Nothing ->
                    project

        Elm.Project.Package packageInfo ->
            case find (isPackageWithName packageName) packageInfo.deps of
                Just packageDep ->
                    Elm.Project.Package
                        { packageInfo
                            | deps = List.filter (isPackageWithName packageName >> not) packageInfo.deps
                            , testDeps = packageDep :: packageInfo.testDeps
                        }

                Nothing ->
                    project


isPackageWithName : String -> ( Elm.Package.Name, a ) -> Bool
isPackageWithName packageName ( packageName_, _ ) =
    packageName == Elm.Package.toString packageName_


thing : Dict String Dependency -> String -> Elm.Project.ApplicationInfo -> Maybe Project
thing dependencies packageNameStr application =
    case find (isPackageWithName packageNameStr) application.depsDirect of
        Just ( packageName, version ) ->
            Elm.Project.Application
                { application
                    | depsDirect = List.filter (isPackageWithName packageNameStr >> not) application.depsDirect
                    , depsIndirect =
                        if isADependencyOfAnotherDependency packageName application.depsDirect dependencies then
                            ( packageName, version ) :: application.depsIndirect

                        else
                            application.depsIndirect
                }
                |> Just

        Nothing ->
            Nothing


isADependencyOfAnotherDependency : Elm.Package.Name -> Elm.Project.Deps a -> Dict String Dependency -> Bool
isADependencyOfAnotherDependency packageName deps dependencies =
    List.any
        (\( depName, _ ) ->
            case
                Dict.get (Elm.Package.toString depName) dependencies
                    |> Maybe.map Dependency.elmJson
            of
                Just (Elm.Project.Package packageInfo) ->
                    List.any (\( depDependencyName, _ ) -> depDependencyName == packageName) packageInfo.deps

                _ ->
                    False
        )
        deps


{-| Find the first element that satisfies a predicate and return
Just that element. If none match, return Nothing.

    find (\num -> num > 5) [ 2, 4, 6, 8 ] == Just 6

-}
find : (a -> Bool) -> List a -> Maybe a
find predicate list =
    case list of
        [] ->
            Nothing

        first :: rest ->
            if predicate first then
                Just first

            else
                find predicate rest


onlyTestDependencyError : Rule.ElmJsonKey -> Dict String Dependency -> String -> Error scope
onlyTestDependencyError elmJsonKey dependencies packageName =
    Rule.errorForElmJsonWithFix elmJsonKey
        (\elmJson ->
            { message = "`" ++ packageName ++ "` should be moved to test-dependencies"
            , details =
                [ "This package is not used in the source code, but it is used in tests, and should therefore be moved to the test dependencies. To do so, I recommend running the following commands:"
                , "    elm-json uninstall " ++ packageName ++ "\n" ++ "    elm-json install --test " ++ packageName
                ]
            , range = findPackageNameInElmJson packageName elmJson
            }
        )
        (addTestDependency packageName >> removeProjectDependency dependencies packageName >> Just)


testError : Rule.ElmJsonKey -> String -> Error scope
testError elmJsonKey packageName =
    Rule.errorForElmJsonWithFix elmJsonKey
        (\elmJson ->
            { message = "Unused test dependency `" ++ packageName ++ "`"
            , details =
                [ "To remove it, I recommend running the following command:"
                , "    elm-json uninstall " ++ packageName
                ]
            , range = findPackageNameInElmJson packageName elmJson
            }
        )
        (removeTestDependency packageName >> Just)


findPackageNameInElmJson : String -> String -> Range
findPackageNameInElmJson packageName elmJson =
    elmJson
        |> String.lines
        |> List.indexedMap Tuple.pair
        |> List.filterMap
            (\( row, line ) ->
                case String.indexes ("\"" ++ packageName ++ "\"") line of
                    [] ->
                        Nothing

                    column :: _ ->
                        Just
                            { start =
                                { row = row + 1
                                , column = column + 2
                                }
                            , end =
                                { row = row + 1
                                , column = column + String.length packageName + 2
                                }
                            }
            )
        |> List.head
        |> Maybe.withDefault { start = { row = 1, column = 1 }, end = { row = 10000, column = 1 } }

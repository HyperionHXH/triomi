package triomi.desktop;

import eu.kanade.tachiyomi.source.model.*;
import eu.kanade.tachiyomi.source.online.HttpSource;
import graphql.ExecutionInput;
import graphql.ExecutionResult;
import graphql.GraphQL;
import graphql.GraphQLContext;
import graphql.schema.GraphQLSchema;
import io.javalin.json.JavalinJackson3;
import java.net.URLClassLoader;
import java.nio.file.Path;
import java.util.*;
import kotlin.Pair;
import kotlin.coroutines.Continuation;
import kotlin.coroutines.EmptyCoroutineContext;
import kotlin.coroutines.intrinsics.IntrinsicsKt;
import kotlinx.coroutines.BuildersKt;
import suwayomi.tachidesk.graphql.server.GraphQLSchemaProvider;
import suwayomi.tachidesk.manga.impl.util.source.GetSource;
import suwayomi.tachidesk.server.JavalinSetup;
import suwayomi.tachidesk.server.user.UserType;

public final class NullableFilterSearchTest {
    static int assertions;
    static void check(boolean condition, String label) {
        assertions++;
        if (!condition) throw new AssertionError(label);
    }
    static Map<String,Object> row(String type, Object state) {
        Map<String,Object> result = new LinkedHashMap<>();
        result.put("type", type);
        result.put("state", state);
        return result;
    }
    static void rejected(Runnable action, String label) {
        try { action.run(); throw new AssertionError(label); }
        catch (IllegalArgumentException expected) { assertions++; }
    }
    static Filter.Sort sort() { return new Filter.Sort("Order", new String[]{"Title", "Date"}, new Filter.Sort.Selection(1,false)) {}; }
    static FilterList filters() {
        return new FilterList(new Filter.Header("Info"), new Filter.Group<Filter<?>>("Outer", List.of(
                new Filter.CheckBox("Chosen", false) {}, new Filter.Group<Filter<?>>("Inner", List.of(sort())) {})) {});
    }
    static List<?> snapshot(Object selection) {
        return List.of(row("header", null), row("group", List.of(row("check", true), row("group", List.of(row("sort", selection))))));
    }
    static Filter.Sort nestedSort(FilterList filters) {
        return (Filter.Sort)((Filter.Group<?>)((Filter.Group<?>)filters.get(1)).getState().get(1)).getState().get(0);
    }
    public static void main(String[] args) throws Exception {
        FilterList nullable = filters();
        NullableFilterSearch.apply(nullable, snapshot(null));
        check(nestedSort(nullable).getState() == null, "nested group sort clears non-null default");
        NullableFilterSearch.apply(nullable, snapshot(Map.of("index", 0, "ascending", true)));
        check(nestedSort(nullable).getState().getIndex() == 0 && nestedSort(nullable).getState().getAscending(), "nested non-null state");
        FilterList atomic = new FilterList(new Filter.CheckBox("a", false) {}, sort());
        rejected(() -> NullableFilterSearch.apply(atomic, List.of(row("check",true), row("sort",Map.of("index",99,"ascending",true)))), "bounds");
        check(!((Filter.CheckBox)atomic.get(0)).getState(), "invalid snapshot leaves earlier states untouched");
        rejected(() -> NullableFilterSearch.apply(atomic, List.of(row("check",true))), "changed shape");
        rejected(() -> NullableFilterSearch.apply(atomic, List.of(row("text","true"), row("sort",null))), "changed type");
        rejected(() -> NullableFilterSearch.apply(atomic, List.of(row("check",true), row("sort",Map.of("index",0.5,"ascending",true)))), "fraction index");
        rejected(() -> NullableFilterSearch.apply(atomic, List.of(row("check","true"), row("sort",null))), "strict boolean");
        Map<String,Object> missing = new HashMap<>(); missing.put("type","sort");
        rejected(() -> NullableFilterSearch.apply(new FilterList(sort()),List.of(missing)), "missing versus null");
        List<Filter<?>> big = new ArrayList<>(); List<Object> bigRows = new ArrayList<>();
        for (int i=0;i<65537;i++) { big.add(new Filter.Header("")); bigRows.add(row("header",null)); }
        rejected(() -> NullableFilterSearch.apply(new FilterList(big),bigRows), "node limit");
        Filter<?> deep = sort(); Object deepRows = row("sort",null);
        for(int i=0;i<9;i++) { deep = new Filter.Group<Filter<?>>("",List.of(deep)) {}; deepRows = row("group",List.of(deepRows)); }
        Filter<?> tooDeep = deep; Object tooDeepRows = deepRows;
        rejected(() -> NullableFilterSearch.apply(new FilterList(tooDeep),List.of(tooDeepRows)), "depth limit");

        suwayomi.tachidesk.server.ServerSetupKt.applicationSetup();
        GraphQLSchemaProvider.INSTANCE.init();
        NullableFilterSearch.install();
        NullableFilterSearch.install();
        GraphQLSchema schema = BuildersKt.runBlocking(EmptyCoroutineContext.INSTANCE,
                (scope, continuation) -> GraphQLSchemaProvider.INSTANCE.getSchema(continuation));
        check(schema.getMutationType().getFieldDefinition("fetchSourceManga").getArgument("triomiFilters") != null, "schema argument installed");
        GetSource.INSTANCE.registerSource(new Pair<>(0L,new Fixture()));
        GraphQL graph = GraphQL.newGraphQL(schema).build();
        String query = "mutation($input: FetchSourceMangaInput!, $triomiFilters: String) { fetchSourceManga(input:$input, triomiFilters:$triomiFilters) { hasNextPage mangas { id sourceId url title genre status thumbnailUrl thumbnailUrlLastFetched } } }";
        Map<String,Object> input = Map.of("source","0","page",2,"type","SEARCH","query","owned-query");
        String json = new JavalinJackson3().toJsonString(snapshot(null),List.class);
        ExecutionInput execution = ExecutionInput.newExecutionInput().query(query)
                .variables(Map.of("input",input,"triomiFilters",json)).graphQLContext(context -> context.put(JavalinSetup.Attribute.TachideskUser.INSTANCE,new UserType.Admin(1))).build();
        ExecutionResult actual = graph.execute(execution);
        check(actual.getErrors().isEmpty(), "nullable GraphQL execution: " + actual.getErrors());
        Map<?,?> payload = (Map<?,?>)((Map<?,?>)actual.getData()).get("fetchSourceManga");
        check(Boolean.TRUE.equals(payload.get("hasNextPage")), "paging preserved");
        List<?> mangas = (List<?>)payload.get("mangas");
        check(mangas.size()==2 && "/z".equals(((Map<?,?>)mangas.get(0)).get("url")) && "/a".equals(((Map<?,?>)mangas.get(1)).get("url")), "source order and standard manga DTO preserved");
        ExecutionResult denied = graph.execute(execution.transform(builder -> builder.graphQLContext(context -> context.put(JavalinSetup.Attribute.TachideskUser.INSTANCE,UserType.Visitor.INSTANCE))));
        check(!denied.getErrors().isEmpty(), "visitor rejected");
        ExecutionResult defaultPath = graph.execute(ExecutionInput.newExecutionInput()
                .query("mutation($input: FetchSourceMangaInput!) { fetchSourceManga(input:$input) { hasNextPage } }")
                .variables(Map.of("input",Map.of("source","0","page",1,"type","SEARCH","query","default")))
                .graphQLContext(context -> context.put(JavalinSetup.Attribute.TachideskUser.INSTANCE,new UserType.Admin(1))).build());
        check(defaultPath.getErrors().isEmpty(), "original datafetcher preserved: " + defaultPath.getErrors());
        if (args.length > 0) {
            try(URLClassLoader loader = new URLClassLoader(new java.net.URL[]{Path.of(args[0]).toUri().toURL()}, NullableFilterSearchTest.class.getClassLoader())) {
                Class<?> localization = loader.loadClass("keiyoushi.a.a.a");
                kotlin.jvm.functions.Function1<String,String> resource = lang -> "assets/i18n/messages_" + lang + ".properties";
                Object i18n = localization.getDeclaredConstructors()[0].newInstance("en",Set.of("en"),"en",loader,resource);
                Class<?> option = loader.loadClass("eu.kanade.tachiyomi.extension.all.mangadex.x");
                Object values = java.lang.reflect.Array.newInstance(option,6);
                for(int i=0;i<6;i++) java.lang.reflect.Array.set(values,i,option.getDeclaredConstructor(String.class,String.class).newInstance("Option " + i,i==5?"relevance":"title"));
                Filter.Sort original = (Filter.Sort)loader.loadClass("eu.kanade.tachiyomi.extension.all.mangadex.w").getDeclaredConstructor(localization,values.getClass()).newInstance(i18n,values);
                check(original.getState()!=null && original.getState().getIndex()==5 && !original.getState().getAscending(), "real MangaDex relevance default");
                java.lang.reflect.Method append = original.getClass().getMethod("a",okhttp3.HttpUrl.Builder.class,String.class);
                okhttp3.HttpUrl.Builder before = new okhttp3.HttpUrl.Builder().scheme("https").host("api.mangadex.org");
                append.invoke(original,before,"");
                check("desc".equals(before.build().queryParameter("order[relevance]")),"real MangaDex default request parameter");
                NullableFilterSearch.apply(new FilterList(original),List.of(row("sort",null)));
                check(original.getState()==null, "real MangaDex explicit null applied");
                okhttp3.HttpUrl.Builder after = new okhttp3.HttpUrl.Builder().scheme("https").host("api.mangadex.org");
                append.invoke(original,after,"");
                check(after.build().querySize()==0,"real MangaDex nullable state omits sorting parameter");
            }
        }
        System.out.println("NullableFilterSearch PASS: " + assertions + " assertions; real schema, async nested-null search, auth and original branch");
        System.exit(0);
    }
    static final class Fixture extends HttpSource {
        public long getId() { return 0; }
        public String getName() { return "Nullable sort fixture"; }
        public String getLang() { return "en"; }
        public String getBaseUrl() { return "https://triomi.invalid"; }
        public boolean getSupportsLatest() { return false; }
        public FilterList getFilterList() { return filters(); }
        public Object getSearchManga(int page,String query,FilterList filters,Continuation<? super MangasPage> completion) {
            if("default".equals(query)) {
                check(nestedSort(filters).getState()!=null,"original GraphQL retains plugin defaults");
                return new MangasPage(List.of(),false);
            }
            check(page==2 && "owned-query".equals(query) && nestedSort(filters).getState()==null,"search receives explicit null and invocation input");
            check(((Filter.CheckBox)((Filter.Group<?>)filters.get(1)).getState().get(0)).getState(),"sibling checkbox applied");
            SManga z = SManga.Companion.create(); z.setUrl("/z"); z.setTitle("Z");
            SManga a = SManga.Companion.create(); a.setUrl("/a"); a.setTitle("A");
            new Thread(() -> { try { Thread.sleep(10); } catch(InterruptedException failure) { throw new RuntimeException(failure); } completion.resumeWith(new MangasPage(List.of(z,a),true)); }).start();
            return IntrinsicsKt.getCOROUTINE_SUSPENDED();
        }
    }
}

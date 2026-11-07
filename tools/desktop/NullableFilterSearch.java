package triomi.desktop;

import eu.kanade.tachiyomi.source.Source;
import eu.kanade.tachiyomi.source.model.Filter;
import eu.kanade.tachiyomi.source.model.FilterList;
import eu.kanade.tachiyomi.source.model.MangasPage;
import graphql.Scalars;
import graphql.schema.DataFetcher;
import graphql.schema.FieldCoordinates;
import graphql.schema.GraphQLArgument;
import graphql.schema.GraphQLCodeRegistry;
import graphql.schema.GraphQLFieldDefinition;
import graphql.schema.GraphQLObjectType;
import graphql.schema.GraphQLSchema;
import io.javalin.json.JavalinJackson3;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import kotlin.ResultKt;
import kotlin.coroutines.Continuation;
import kotlin.coroutines.CoroutineContext;
import kotlin.coroutines.EmptyCoroutineContext;
import kotlin.coroutines.intrinsics.IntrinsicsKt;
import kotlinx.coroutines.BuildersKt;
import kotlinx.coroutines.CompletableDeferredKt;
import suwayomi.tachidesk.graphql.mutations.SourceMutation.FetchSourceMangaPayload;
import suwayomi.tachidesk.graphql.server.GraphQLSchemaProvider;
import suwayomi.tachidesk.graphql.types.MangaType;
import suwayomi.tachidesk.manga.impl.MangaList;
import suwayomi.tachidesk.manga.impl.util.source.GetSource;
import suwayomi.tachidesk.manga.model.dataclass.MangaDataClass;
import suwayomi.tachidesk.manga.model.dataclass.PagedMangaListDataClass;
import suwayomi.tachidesk.server.JavalinSetup;
import suwayomi.tachidesk.server.user.UserType;
import suwayomi.tachidesk.server.user.UserTypeKt;

/** Adds explicit nullable sort state to the otherwise unchanged private GraphQL API. */
public final class NullableFilterSearch {
    private static final String ARGUMENT = "triomiFilters";
    private static final int MAX_NODES = 65536;
    private static final int MAX_DEPTH = 8;
    private static final int MAX_JSON_LENGTH = 16 * 1024 * 1024;

    private NullableFilterSearch() {}

    /** Call after applicationSetup and schema init, before starting Javalin. */
    public static void install() throws InterruptedException {
        GraphQLSchemaProvider provider = GraphQLSchemaProvider.INSTANCE;
        GraphQLSchema schema = BuildersKt.runBlocking(EmptyCoroutineContext.INSTANCE,
                (scope, continuation) -> provider.getSchema(continuation));
        provider.setSchemaFuture(CompletableDeferredKt.CompletableDeferred(extend(schema)));
    }

    static GraphQLSchema extend(GraphQLSchema schema) {
        GraphQLObjectType mutation = schema.getMutationType();
        GraphQLFieldDefinition original = mutation.getFieldDefinition("fetchSourceManga");
        if (original.getArgument(ARGUMENT) != null) return schema;
        DataFetcher<?> originalFetcher = schema.getCodeRegistry().getDataFetcher(mutation, original);
        GraphQLFieldDefinition extended = original.transform(builder -> builder.argument(
                GraphQLArgument.newArgument().name(ARGUMENT).type(Scalars.GraphQLString).build()));
        GraphQLObjectType extendedMutation = mutation.transform(builder -> builder.field(extended));
        GraphQLCodeRegistry registry = schema.getCodeRegistry().transform(builder -> builder.dataFetcher(
                FieldCoordinates.coordinates(mutation.getName(), original.getName()), (DataFetcher<Object>) environment -> {
                    String json = environment.getArgument(ARGUMENT);
                    if (json == null) return originalFetcher.get(environment);
                    // Match upstream RequireAuthDirectiveWiring for the new branch.
                    UserType user = environment.getGraphQlContext().get(
                            JavalinSetup.Attribute.TachideskUser.INSTANCE);
                    UserTypeKt.requireUser(user);
                    if (environment.getArguments().containsKey("userId")) {
                        throw new IllegalArgumentException("userId is reserved for RequireAuth");
                    }
                    Map<?, ?> input = environment.getArgument("input");
                    if (input == null || !"SEARCH".equals(String.valueOf(input.get("type")))) {
                        throw new IllegalArgumentException("Nullable filters require a SEARCH operation");
                    }
                    long sourceId = Long.parseLong(String.valueOf(input.get("source")));
                    int page = integer(input.get("page"));
                    if (page < 1) throw invalid();
                    String query = input.get("query") == null ? "" : (String) input.get("query");
                    String clientMutationId = (String) input.get("clientMutationId");
                    List<?> rows = parseRows(json);
                    return JavalinSetup.INSTANCE.future((scope, completion) ->
                            NullableFilterSearch.<Source>suspendThen(continuation -> GetSource.INSTANCE.getSourceOrNull(sourceId, continuation),
                                    source -> {
                                        if (source == null) throw new IllegalArgumentException("Unknown source");
                                        FilterList filters = apply(source.getFilterList(), rows);
                                        return NullableFilterSearch.<MangasPage>suspendThen(continuation -> source.getSearchManga(
                                                page, query, filters, continuation),
                                                result -> payload(result, sourceId, clientMutationId), completion);
                                    }, completion));
                }));
        return schema.transform(builder -> builder.mutation(extendedMutation).codeRegistry(registry));
    }

    private static FetchSourceMangaPayload payload(MangasPage page, long sourceId, String mutationId) {
        PagedMangaListDataClass result = MangaList.INSTANCE.processEntries(page, sourceId);
        // The REST helper does not preserve database query order; GraphQL does.
        Map<String, Integer> positions = new LinkedHashMap<>();
        for (int i = 0; i < page.getMangas().size(); i++) positions.putIfAbsent(page.getMangas().get(i).getUrl(), i);
        List<MangaDataClass> ordered = new ArrayList<>(result.getMangaList());
        ordered.sort(Comparator.comparingInt(row -> positions.get(row.getUrl())));
        List<MangaType> mangas = ordered.stream().map(MangaType::new).toList();
        return new FetchSourceMangaPayload(mutationId, mangas, result.getHasNextPage());
    }

    private static List<?> parseRows(String json) {
        if (json.length() > MAX_JSON_LENGTH) throw invalid();
        Object rows = new JavalinJackson3().fromJsonString(json, List.class);
        if (!(rows instanceof List<?> list)) throw invalid();
        return list;
    }

    /** Validates the complete snapshot before mutating any source-owned filter. */
    static FilterList apply(FilterList filters, List<?> rows) {
        List<Runnable> assignments = new ArrayList<>();
        validate(filters, rows, 0, new int[]{0}, new IdentityHashMap<>(), assignments);
        assignments.forEach(Runnable::run);
        return filters;
    }

    private static void validate(List<?> filters, List<?> rows, int depth, int[] count,
            IdentityHashMap<Filter<?>, Boolean> ancestors, List<Runnable> assignments) {
        if (depth > MAX_DEPTH || rows.size() != filters.size()) throw invalid();
        for (int i = 0; i < filters.size(); i++) {
            if (++count[0] > MAX_NODES || !(filters.get(i) instanceof Filter<?> filter)
                    || !(rows.get(i) instanceof Map<?, ?> row) || !row.containsKey("state")) throw invalid();
            if (row.containsKey("index") && integer(row.get("index")) != i) throw invalid();
            Object state = row.get("state");
            String type = type(filter);
            if (!type.equals(row.get("type"))) throw invalid();
            switch (type) {
                case "header", "separator" -> {
                    if (state != null) throw invalid();
                }
                case "group" -> {
                    if (!(state instanceof List<?> children) || ancestors.put(filter, true) != null) throw invalid();
                    validate((List<?>) filter.getState(), children, depth + 1, count, ancestors, assignments);
                    ancestors.remove(filter);
                }
                case "select" -> {
                    int selected = integer(state);
                    if (selected < 0 || selected >= ((Filter.Select<?>) filter).getValues().length) throw invalid();
                    assignments.add(() -> ((Filter.Select<?>) filter).setState(selected));
                }
                case "tri" -> {
                    int selected = integer(state);
                    if (selected < 0 || selected > 2) throw invalid();
                    assignments.add(() -> ((Filter.TriState) filter).setState(selected));
                }
                case "text" -> {
                    if (!(state instanceof String text)) throw invalid();
                    assignments.add(() -> ((Filter.Text) filter).setState(text));
                }
                case "check" -> {
                    if (!(state instanceof Boolean checked)) throw invalid();
                    assignments.add(() -> ((Filter.CheckBox) filter).setState(checked));
                }
                case "sort" -> {
                    Filter.Sort sort = (Filter.Sort) filter;
                    Filter.Sort.Selection selection;
                    if (state == null) selection = null;
                    else {
                        if (!(state instanceof Map<?, ?> selected) || !(selected.get("ascending") instanceof Boolean ascending)) {
                            throw invalid();
                        }
                        int index = integer(selected.get("index"));
                        if (index < 0 || index >= sort.getValues().length) throw invalid();
                        selection = new Filter.Sort.Selection(index, ascending);
                    }
                    assignments.add(() -> sort.setState(selection));
                }
                default -> throw invalid();
            }
        }
    }

    private static String type(Filter<?> filter) {
        if (filter instanceof Filter.Header) return "header";
        if (filter instanceof Filter.Separator) return "separator";
        if (filter instanceof Filter.Select<?>) return "select";
        if (filter instanceof Filter.Text) return "text";
        if (filter instanceof Filter.CheckBox) return "check";
        if (filter instanceof Filter.TriState) return "tri";
        if (filter instanceof Filter.Group<?>) return "group";
        if (filter instanceof Filter.Sort) return "sort";
        throw invalid();
    }

    private static int integer(Object value) {
        if (!(value instanceof Byte || value instanceof Short || value instanceof Integer || value instanceof Long)) throw invalid();
        long number = ((Number) value).longValue();
        if (number < Integer.MIN_VALUE || number > Integer.MAX_VALUE) throw invalid();
        return (int) number;
    }

    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException("Invalid or changed desktop filter snapshot");
    }

    @FunctionalInterface
    private interface SuspendCall<T> { Object invoke(Continuation<? super T> continuation); }

    /** Keeps the upstream coroutine context through both possibly suspended calls. */
    private static <T> Object suspendThen(SuspendCall<T> call, Function<T, Object> next,
            Continuation<?> completion) {
        Object result = call.invoke(new Continuation<T>() {
            @Override public CoroutineContext getContext() { return completion.getContext(); }
            @Override public void resumeWith(Object resumed) {
                try {
                    ResultKt.throwOnFailure(resumed);
                    @SuppressWarnings("unchecked") T value = (T) resumed;
                    Object mapped = next.apply(value);
                    if (mapped != IntrinsicsKt.getCOROUTINE_SUSPENDED()) completion.resumeWith(mapped);
                } catch (Throwable failure) {
                    completion.resumeWith(ResultKt.createFailure(failure));
                }
            }
        });
        if (result == IntrinsicsKt.getCOROUTINE_SUSPENDED()) return result;
        @SuppressWarnings("unchecked") T value = (T) result;
        return next.apply(value);
    }
}

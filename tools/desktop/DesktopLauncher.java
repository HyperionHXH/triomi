package triomi.desktop;

/** Starts the pinned server after its configuration and database are ready. */
public final class DesktopLauncher {
    private DesktopLauncher() {}

    public static void main(String[] args) throws InterruptedException {
        // The upstream main starts schema generation before registering config.
        // Its eager table initialization can then poison ChapterTable on Windows.
        suwayomi.tachidesk.server.ServerSetupKt.applicationSetup();
        suwayomi.tachidesk.graphql.server.GraphQLSchemaProvider.INSTANCE.init();
        NullableFilterSearch.install();
        suwayomi.tachidesk.server.JavalinSetup.INSTANCE.javalinSetup();
    }
}

package km.hawiya.matcher;

import com.machinezoo.sourceafis.FingerprintTemplate;
import io.javalin.Javalin;
import io.javalin.http.BadRequestResponse;
import io.javalin.http.Context;
import io.javalin.http.HttpStatus;
import io.javalin.http.UnauthorizedResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * API HTTP du service de comparaison. Appelée UNIQUEMENT par le backend, sur le
 * réseau interne Docker, avec l'en-tête « X-Cle-Matcher » (secret partagé).
 *
 * Les modèles et images circulent en base64 dans du JSON.
 */
public final class Application {

    private static final Logger LOG = LoggerFactory.getLogger(Application.class);
    static final String ENTETE_CLE = "X-Cle-Matcher";

    // --- Corps des requêtes et réponses ---
    public record DemandeModele(String image, double dpi) {
    }

    public record DemandeComparaison(String sonde, String candidat) {
    }

    public record DemandeMatrice(List<String> modeles) {
    }

    public record ModeleDoigt(int doigt, String modele) {
    }

    public record DemandeIdentification(List<ModeleDoigt> doigts, String fusion, Integer limite) {
    }

    public record DemandeGalerie(List<ModeleDoigt> doigts) {
    }

    private Application() {
    }

    /** Construit l'application (non démarrée), pour les tests et pour main(). */
    public static Javalin creer(Galerie galerie, String cle, Runnable recharger) {
        if (cle == null || cle.length() < 16) {
            throw new IllegalStateException("MATCHER_CLE doit contenir au moins 16 caractères");
        }
        byte[] cleAttendue = cle.getBytes(StandardCharsets.UTF_8);

        Javalin app = Javalin.create(config -> {
            config.showJavalinBanner = false;
            config.http.maxRequestSize = 20_000_000L; // images en base64
        });

        // Toutes les routes sauf /sante exigent la clé (comparaison à temps constant).
        app.before(ctx -> {
            if (ctx.path().equals("/sante")) {
                return;
            }
            String recue = ctx.header(ENTETE_CLE);
            if (recue == null || !MessageDigest.isEqual(cleAttendue, recue.getBytes(StandardCharsets.UTF_8))) {
                throw new UnauthorizedResponse("Clé du matcher absente ou invalide");
            }
        });

        app.exception(IllegalArgumentException.class, (e, ctx) ->
                ctx.status(HttpStatus.BAD_REQUEST).json(Map.of("erreur", String.valueOf(e.getMessage()))));

        app.get("/sante", ctx -> ctx.json(Map.of(
                "statut", "ok",
                "version", Moteur.version(),
                "personnes", galerie.nombrePersonnes(),
                "modeles", galerie.nombreModeles())));

        // Image prétraitée → modèle
        app.post("/modeles", ctx -> {
            var demande = ctx.bodyAsClass(DemandeModele.class);
            if (demande.dpi() < 100 || demande.dpi() > 2000) {
                throw new BadRequestResponse("dpi hors limites");
            }
            byte[] modele = Moteur.extraire(decoder(demande.image(), "image"), demande.dpi());
            ctx.json(Map.of("modele", encoder(modele), "version", Moteur.version()));
        });

        // Comparaison 1:1
        app.post("/comparer", ctx -> {
            var demande = ctx.bodyAsClass(DemandeComparaison.class);
            double score = Moteur.comparer(lireModele(demande.sonde()), lireModele(demande.candidat()));
            ctx.json(Map.of("score", score));
        });

        // Tous les scores entre une liste de modèles (outil d'évaluation).
        app.post("/matrice", ctx -> {
            var modeles = ctx.bodyAsClass(DemandeMatrice.class).modeles();
            if (modeles == null || modeles.size() > 2000) {
                throw new BadRequestResponse("Liste de modèles absente ou trop longue");
            }
            var lus = modeles.stream().map(Application::lireModele).toList();
            double[][] scores = new double[lus.size()][lus.size()];
            for (int i = 0; i < lus.size(); i++) {
                var comparateur = new com.machinezoo.sourceafis.FingerprintMatcher(lus.get(i));
                for (int j = 0; j < lus.size(); j++) {
                    // Diagonale à -1 : un modèle comparé à lui-même n'a pas de sens.
                    scores[i][j] = i == j ? -1 : comparateur.match(lus.get(j));
                }
            }
            ctx.json(Map.of("scores", scores));
        });

        // Recherche 1:N d'une main (ou d'une personne entière pour l'anti-doublon)
        app.post("/identifier", ctx -> {
            var demande = ctx.bodyAsClass(DemandeIdentification.class);
            var fusion = demande.fusion() == null
                    ? Galerie.Fusion.SOMME
                    : Galerie.Fusion.valueOf(demande.fusion().toUpperCase());
            int limite = demande.limite() == null ? 5 : Math.max(1, Math.min(demande.limite(), 50));
            ctx.json(Map.of("candidats", galerie.identifier(lireDoigts(demande.doigts()), fusion, limite)));
        });

        app.put("/galerie/{id}", ctx -> {
            galerie.ajouter(ctx.pathParam("id"), lireDoigts(ctx.bodyAsClass(DemandeGalerie.class).doigts()));
            ctx.status(HttpStatus.NO_CONTENT);
        });

        app.delete("/galerie/{id}", ctx ->
                ctx.status(galerie.retirer(ctx.pathParam("id")) ? HttpStatus.NO_CONTENT : HttpStatus.NOT_FOUND));

        app.post("/galerie/recharger", ctx -> {
            recharger.run();
            ctx.json(Map.of("personnes", galerie.nombrePersonnes()));
        });

        return app;
    }

    private static Map<Integer, FingerprintTemplate> lireDoigts(List<ModeleDoigt> doigts) {
        if (doigts == null || doigts.isEmpty()) {
            throw new BadRequestResponse("Aucun doigt fourni");
        }
        Map<Integer, FingerprintTemplate> lus = new HashMap<>();
        for (var d : doigts) {
            if (d.doigt() < 1 || d.doigt() > 10) {
                throw new BadRequestResponse("Doigt hors limites (ISO 1 à 10) : " + d.doigt());
            }
            lus.put(d.doigt(), lireModele(d.modele()));
        }
        return lus;
    }

    private static FingerprintTemplate lireModele(String base64) {
        try {
            return Moteur.lire(decoder(base64, "modele"));
        } catch (RuntimeException e) {
            throw new BadRequestResponse("Modèle illisible");
        }
    }

    private static byte[] decoder(String base64, String champ) {
        if (base64 == null || base64.isEmpty()) {
            throw new BadRequestResponse("Champ « " + champ + " » absent");
        }
        try {
            return Base64.getDecoder().decode(base64);
        } catch (IllegalArgumentException e) {
            throw new BadRequestResponse("Champ « " + champ + " » : base64 invalide");
        }
    }

    private static String encoder(byte[] octets) {
        return Base64.getEncoder().encodeToString(octets);
    }

    public static void main(String[] args) {
        var galerie = new Galerie();
        String url = System.getenv("MATCHER_DB_URL");
        Runnable recharger = () -> {
            if (url == null || url.isBlank()) {
                LOG.info("MATCHER_DB_URL absent : galerie vide (mode évaluation)");
                return;
            }
            try {
                int n = ChargeurGalerie.charger(galerie, url,
                        System.getenv("MATCHER_DB_UTILISATEUR"), System.getenv("MATCHER_DB_MOT_DE_PASSE"));
                LOG.info("Galerie chargée : {} personnes", n);
            } catch (Exception e) {
                // Le service démarre quand même : la galerie pourra être rechargée.
                LOG.error("Chargement de la galerie impossible : {}", e.getMessage());
            }
        };
        recharger.run();
        int port = Integer.parseInt(System.getenv().getOrDefault("MATCHER_PORT", "8080"));
        creer(galerie, System.getenv("MATCHER_CLE"), recharger).start(port);
        LOG.info("Matcher {} à l'écoute sur le port {}", Moteur.version(), port);
    }
}

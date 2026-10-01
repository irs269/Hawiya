package km.hawiya.matcher;

import com.machinezoo.sourceafis.FingerprintTemplate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;

/**
 * Charge la galerie au démarrage depuis la table « empreintes » du backend,
 * avec un compte PostgreSQL en LECTURE SEULE.
 */
public final class ChargeurGalerie {

    private static final Logger LOG = LoggerFactory.getLogger(ChargeurGalerie.class);

    private ChargeurGalerie() {
    }

    /** Renvoie le nombre de personnes chargées. */
    public static int charger(Galerie galerie, String url, String utilisateur, String motDePasse) throws SQLException {
        Map<String, Map<Integer, FingerprintTemplate>> parPersonne = new HashMap<>();
        int ignores = 0;
        try (var connexion = DriverManager.getConnection(url, utilisateur, motDePasse)) {
            connexion.setReadOnly(true);
            try (var requete = connexion.prepareStatement(
                    "SELECT citoyen_id, doigt, modele, version_moteur FROM empreintes")) {
                try (var lignes = requete.executeQuery()) {
                    while (lignes.next()) {
                        // Un modèle d'une autre version du moteur n'est pas comparable.
                        if (!Moteur.version().equals(lignes.getString("version_moteur"))) {
                            ignores++;
                            continue;
                        }
                        parPersonne
                                .computeIfAbsent(lignes.getString("citoyen_id"), k -> new HashMap<>())
                                .put(lignes.getInt("doigt"), Moteur.lire(lignes.getBytes("modele")));
                    }
                }
            }
        }
        galerie.vider();
        parPersonne.forEach(galerie::ajouter);
        if (ignores > 0) {
            LOG.warn("{} modèles ignorés : version du moteur différente de {}", ignores, Moteur.version());
        }
        return parPersonne.size();
    }
}
